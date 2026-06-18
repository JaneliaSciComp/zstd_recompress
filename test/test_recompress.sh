#!/usr/bin/env bash
# Test suite for zstd_recompress.sh and zstd_verify.sh.
#
# Creates a synthetic source tree containing:
#   - zstd-compressed files WITHOUT content size (simulating TensorStore output)
#   - a zstd-compressed file that already has content size (should be copied unchanged)
#   - a non-zstd file (plain text, should be copied unchanged)
#
# Then exercises in-place and mirror modes with and without a manifest, and
# verifies results with zstd_verify.sh.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RECOMPRESS="$SCRIPT_DIR/zstd_recompress.sh"
VERIFY="$SCRIPT_DIR/zstd_verify.sh"

# Activate the pixi environment so zstd, xxh64sum, etc. are on PATH here too.
if [[ -f "$SCRIPT_DIR/pixi.toml" ]]; then
    if ! eval "$(pixi shell-hook --manifest-path "$SCRIPT_DIR/pixi.toml" 2>/dev/null)" 2>/dev/null; then
        echo "WARNING: failed to activate pixi environment; falling back to system PATH" >&2
    fi
fi

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

check() {
    local desc="$1"; shift
    if "$@" &>/dev/null; then
        pass "$desc"
    else
        fail "$desc (command: $*)"
    fi
}

check_not() {
    local desc="$1"; shift
    if ! "$@" &>/dev/null; then
        pass "$desc"
    else
        fail "$desc (expected failure but command succeeded: $*)"
    fi
}

# Returns 0 if FILE is a valid zstd stream.
is_zstd()        { zstd -l "$1" &>/dev/null; }

# Returns 0 if FILE is zstd AND the content size field is present.
has_content_size() {
    local info
    info=$(zstd -l "$1" 2>/dev/null) || return 1
    echo "$info" | awk 'NR==2 { exit ($5 ~ /^[0-9]/) ? 0 : 1 }'
}

# ---------------------------------------------------------------------------
# Set up a temp working directory, cleaned up on exit.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

SRC="$WORK/source"
mkdir -p "$SRC/a/b"

echo "=== Building synthetic source tree ==="

# zstd without content size — pipe through stdin so zstd cannot record size.
# Simulates what TensorStore writes (google/tensorstore#182).
printf 'chunk data alpha\n%.0s' {1..1000} | zstd -3 -o "$SRC/a/chunk_no_size_1" -f --no-progress
printf 'chunk data beta\n%.0s'  {1..1000} | zstd -3 -o "$SRC/a/b/chunk_no_size_2" -f --no-progress

# zstd with content size already present — should be copied, not recompressed.
printf 'chunk data gamma\n%.0s' {1..1000} > "$WORK/raw_gamma"
zstd -3 --content-size -o "$SRC/a/chunk_with_size" -f --no-progress "$WORK/raw_gamma"
rm "$WORK/raw_gamma"

# Plain text file — not zstd, should be copied unchanged.
echo '{"compressor": {"id": "zstd"}}' > "$SRC/.zarray"

echo ""
echo "Source tree:"
find "$SRC" -type f | sort | while read -r f; do
    rel="${f#"$SRC"/}"
    if ! is_zstd "$f"; then
        echo "  $rel: not zstd"
    elif has_content_size "$f"; then
        echo "  $rel: zstd, has content size"
    else
        echo "  $rel: zstd, NO content size"
    fi
done

# Validate the test fixtures themselves.
echo ""
echo "Validating fixtures:"
check     ".zarray is not zstd"               bash -c "! is_zstd '$SRC/.zarray'"
check     "chunk_no_size_1 is zstd"           is_zstd "$SRC/a/chunk_no_size_1"
check_not "chunk_no_size_1 has no content size" has_content_size "$SRC/a/chunk_no_size_1"
check     "chunk_no_size_2 is zstd"           is_zstd "$SRC/a/b/chunk_no_size_2"
check_not "chunk_no_size_2 has no content size" has_content_size "$SRC/a/b/chunk_no_size_2"
check     "chunk_with_size is zstd"           is_zstd "$SRC/a/chunk_with_size"
check     "chunk_with_size has content size"  has_content_size "$SRC/a/chunk_with_size"

# ---------------------------------------------------------------------------
echo ""
echo "=== Test 1: dry-run (no files should be created or modified) ==="
BEFORE=$(find "$SRC" -type f | sort | md5sum)
"$RECOMPRESS" --dry-run --suffix .out "$SRC" >/dev/null
AFTER=$(find "$SRC" -type f | sort | md5sum)
[[ "$BEFORE" == "$AFTER" ]] \
    && pass "source tree unchanged after dry-run" \
    || fail "source tree was modified during dry-run"
check_not "mirror dir not created during dry-run" test -d "${SRC}.out"

# ---------------------------------------------------------------------------
echo ""
echo "=== Test 2: mirror mode with manifest ==="
MANIFEST="$WORK/checksums.xxh64"
"$RECOMPRESS" --suffix .out --manifest "$MANIFEST" --jobs 4 "$SRC" >/dev/null

DST="${SRC}.out"

# All source files have a counterpart in the mirror.
while IFS= read -r f; do
    rel="${f#"$SRC"/}"
    check "mirror contains $rel" test -f "$DST/$rel"
done < <(find "$SRC" -type f | sort)

# Files that needed recompression now have content size in the mirror.
check "chunk_no_size_1 recompressed with content size" \
    has_content_size "$DST/a/chunk_no_size_1"
check "chunk_no_size_2 recompressed with content size" \
    has_content_size "$DST/a/b/chunk_no_size_2"

# File that already had content size is present and still valid.
check "chunk_with_size present and valid in mirror" \
    zstd -t "$DST/a/chunk_with_size"
check "chunk_with_size has content size in mirror" \
    has_content_size "$DST/a/chunk_with_size"

# Non-zstd file copied verbatim.
check ".zarray copied unchanged" \
    diff "$SRC/.zarray" "$DST/.zarray"

# Manifest exists and has one entry per source file.
SRC_COUNT=$(find "$SRC" -type f | wc -l)
MANIFEST_COUNT=$(grep -c '.' "$MANIFEST" 2>/dev/null || echo 0)
[[ "$SRC_COUNT" -eq "$MANIFEST_COUNT" ]] \
    && pass "manifest has $MANIFEST_COUNT entries (one per source file)" \
    || fail "manifest has $MANIFEST_COUNT entries, expected $SRC_COUNT"

# Manifest is sorted by path (second column).
if [[ "$(sort -k2 "$MANIFEST")" == "$(cat "$MANIFEST")" ]]; then
    pass "manifest is sorted by path"
else
    fail "manifest is not sorted"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Test 3: verify — manifest mode ==="
"$VERIFY" --manifest "$MANIFEST" --jobs 4 "$DST" >/dev/null \
    && pass "manifest verification passed" \
    || fail "manifest verification failed"

# Corrupt a mirror file and confirm verify catches it.
echo "corruption" >> "$DST/a/chunk_no_size_1"
"$VERIFY" --manifest "$MANIFEST" --jobs 4 "$DST" >/dev/null \
    && fail "verify should have detected corruption" \
    || pass "verify correctly detected corruption"

# Restore the mirror.
"$RECOMPRESS" --suffix .out --manifest "$MANIFEST" --jobs 4 "$SRC" >/dev/null

# ---------------------------------------------------------------------------
echo ""
echo "=== Test 4: verify — direct mode ==="
"$VERIFY" --suffix .out --jobs 4 "$SRC" >/dev/null \
    && pass "direct verification passed" \
    || fail "direct verification failed"

# ---------------------------------------------------------------------------
echo ""
echo "=== Test 5: in-place mode ==="
INPLACE="$WORK/inplace"
cp -r "$SRC" "$INPLACE"

"$RECOMPRESS" --jobs 4 "$INPLACE" >/dev/null

check "chunk_no_size_1 recompressed in place" \
    has_content_size "$INPLACE/a/chunk_no_size_1"
check "chunk_no_size_2 recompressed in place" \
    has_content_size "$INPLACE/a/b/chunk_no_size_2"
check "chunk_with_size unchanged in place" \
    has_content_size "$INPLACE/a/chunk_with_size"

# Running again should be a no-op (idempotent).
BEFORE=$(find "$INPLACE" -type f -exec md5sum {} \; | sort)
"$RECOMPRESS" --jobs 4 "$INPLACE" >/dev/null
AFTER=$(find "$INPLACE" -type f -exec md5sum {} \; | sort)
[[ "$BEFORE" == "$AFTER" ]] \
    && pass "second in-place run is idempotent" \
    || fail "second in-place run modified files"

# ---------------------------------------------------------------------------
echo ""
echo "=== Results ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo ""
[[ "$FAIL" -eq 0 ]] && echo "All tests passed." || { echo "Some tests FAILED."; exit 1; }
