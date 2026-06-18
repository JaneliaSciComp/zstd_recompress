#!/usr/bin/env bash
# Verify that a mirrored directory produced by zstd_recompress.sh matches its source.
#
# Two modes:
#   Manifest mode (--manifest): verify files in dst against a XXH64 manifest written
#     by zstd_recompress.sh --manifest. Does not require access to the source.
#   Direct mode (no manifest): decompress both src and dst files on the fly and compare
#     their XXH64 hashes. Also runs 'zstd -t' on every zstd file in dst.

set -euo pipefail

# Activate the pixi environment bundled alongside this script so that zstd and
# xxh64sum are available regardless of the caller's PATH.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [[ -f "$SCRIPT_DIR/pixi.toml" ]]; then
    if ! eval "$(pixi shell-hook --manifest-path "$SCRIPT_DIR/pixi.toml" 2>/dev/null)" 2>/dev/null; then
        echo "WARNING: failed to activate pixi environment; falling back to system PATH" >&2
    fi
fi

usage() {
    cat <<EOF
Usage:
  # Direct comparison (src vs dst)
  $0 [OPTIONS] <src_dir> <dst_dir>
  $0 [OPTIONS] --suffix SUF <src_dir> [<src_dir> ...]

  # Manifest-based verification (dst only, no src needed)
  $0 [OPTIONS] --manifest FILE <dst_dir>
  $0 [OPTIONS] --manifest FILE --suffix SUF <src_dir> [<src_dir> ...]

Options:
  -j, --jobs N       Parallel jobs (default: number of CPU cores)
  -m, --manifest F   Verify against a manifest produced by zstd_recompress.sh --manifest.
                     Paths in the manifest are relative to the source directory root,
                     which mirrors the destination directory structure.
  -s, --suffix SUF   Derive each dst_dir as <src_dir><SUF>
  -v, --verbose      Print each file as it is verified
  -h, --help         Show this help

Exit status:
  0   All files verified OK
  1   One or more mismatches, missing files, or errors
EOF
    exit 1
}

JOBS=$(nproc)
MANIFEST=""
SUFFIX=""
VERBOSE=false
POSITIONAL=()

while [[ $# -gt 0 ]]; do
    case $1 in
        -j|--jobs)     JOBS="$2";     shift 2 ;;
        -m|--manifest) MANIFEST="$2"; shift 2 ;;
        -s|--suffix)   SUFFIX="$2";   shift 2 ;;
        -v|--verbose)  VERBOSE=true;  shift   ;;
        -h|--help)     usage ;;
        -*)            echo "Unknown option: $1" >&2; usage ;;
        *)             POSITIONAL+=("$1"); shift ;;
    esac
done

[[ ${#POSITIONAL[@]} -eq 0 ]] && usage

# ---------------------------------------------------------------------------
is_zstd() { zstd -l "$1" &>/dev/null; }
export -f is_zstd

xxh64_of_file()  { xxh64sum "$1" | awk '{print $1}'; }
xxh64_of_stdin() { xxh64sum      | awk '{print $1}'; }
export -f xxh64_of_file xxh64_of_stdin

# ---------------------------------------------------------------------------
# verify_from_manifest ENTRY DST_DIR VERBOSE
#   ENTRY is one line from the manifest: "<hash>  <rel_path>"
verify_from_manifest() {
    local entry="$1" dst_dir="$2" verbose="$3"

    local expected_hash rel dst_file actual_hash
    expected_hash=$(awk '{print $1}' <<< "$entry")
    rel=$(awk '{print $2}' <<< "$entry")
    dst_file="$dst_dir/$rel"

    if [[ ! -f "$dst_file" ]]; then
        echo "MISSING: $dst_file"
        return 1
    fi

    if is_zstd "$dst_file"; then
        if ! zstd -t "$dst_file" &>/dev/null; then
            echo "EMBEDDED CHECKSUM FAIL: $dst_file"
            return 1
        fi
        actual_hash=$(zstd -d --stdout "$dst_file" | xxh64_of_stdin)
    else
        actual_hash=$(xxh64_of_file "$dst_file")
    fi

    if [[ "$actual_hash" != "$expected_hash" ]]; then
        echo "MISMATCH: $rel"
        echo "  expected: $expected_hash"
        echo "  actual:   $actual_hash"
        return 1
    fi

    [[ "$verbose" == true ]] && echo "OK: $rel"
}
export -f verify_from_manifest

# ---------------------------------------------------------------------------
# verify_file SRC_FILE SRC_DIR DST_DIR VERBOSE
verify_file() {
    local src_file="$1" src_dir="$2" dst_dir="$3" verbose="$4"

    local rel="${src_file#"$src_dir"/}"
    local dst_file="$dst_dir/$rel"

    if [[ ! -f "$dst_file" ]]; then
        echo "MISSING: $dst_file"
        return 1
    fi

    local hash_src hash_dst

    if is_zstd "$src_file"; then
        if is_zstd "$dst_file" && ! zstd -t "$dst_file" &>/dev/null; then
            echo "EMBEDDED CHECKSUM FAIL: $dst_file"
            return 1
        fi
        hash_src=$(zstd -d --stdout "$src_file" | xxh64_of_stdin)
        hash_dst=$(zstd -d --stdout "$dst_file" | xxh64_of_stdin)
    else
        hash_src=$(xxh64_of_file "$src_file")
        hash_dst=$(xxh64_of_file "$dst_file")
    fi

    if [[ "$hash_src" != "$hash_dst" ]]; then
        echo "MISMATCH: $rel"
        echo "  src: $hash_src"
        echo "  dst: $hash_dst"
        return 1
    fi

    [[ "$verbose" == true ]] && echo "OK: $rel"
}
export -f verify_file

# ---------------------------------------------------------------------------
OVERALL_STATUS=0

if [[ -n "$MANIFEST" ]]; then
    # ---- Manifest mode ----
    [[ ! -f "$MANIFEST" ]] && { echo "ERROR: manifest not found: $MANIFEST" >&2; exit 1; }

    # Build list of (dst_dir, entry) pairs.
    if [[ -n "$SUFFIX" ]]; then
        # --manifest --suffix <src_dir> [...]
        for src in "${POSITIONAL[@]}"; do
            src=$(realpath "$src")
            dst_dir="${src}${SUFFIX}"
            echo "Verifying (manifest): $dst_dir"
            if [[ ! -d "$dst_dir" ]]; then
                echo "ERROR: destination not found: $dst_dir" >&2
                OVERALL_STATUS=1
                continue
            fi
            FAIL_COUNT=$(
                grep -v '^#' "$MANIFEST" | grep -v '^$' \
                    | parallel -j "$JOBS" --halt never \
                        verify_from_manifest {} "$dst_dir" "$VERBOSE" \
                    | grep -c "^MISSING\|^MISMATCH\|^EMBEDDED" || true
            )
            if [[ "$FAIL_COUNT" -gt 0 ]]; then
                echo "FAILED: $FAIL_COUNT file(s) did not verify"
                OVERALL_STATUS=1
            else
                echo "All files verified OK"
            fi
        done
    else
        # --manifest <dst_dir>
        [[ ${#POSITIONAL[@]} -ne 1 ]] && { echo "ERROR: expected exactly one dst_dir with --manifest (or use --suffix)" >&2; usage; }
        dst_dir=$(realpath "${POSITIONAL[0]}")
        echo "Verifying (manifest): $dst_dir"
        if [[ ! -d "$dst_dir" ]]; then
            echo "ERROR: destination not found: $dst_dir" >&2
            exit 1
        fi
        FAIL_COUNT=$(
            grep -v '^#' "$MANIFEST" | grep -v '^$' \
                | parallel -j "$JOBS" --halt never \
                    verify_from_manifest {} "$dst_dir" "$VERBOSE" \
                | grep -c "^MISSING\|^MISMATCH\|^EMBEDDED" || true
        )
        if [[ "$FAIL_COUNT" -gt 0 ]]; then
            echo "FAILED: $FAIL_COUNT file(s) did not verify"
            OVERALL_STATUS=1
        else
            echo "All files verified OK"
        fi
    fi

else
    # ---- Direct comparison mode ----
    if [[ -n "$SUFFIX" ]]; then
        PAIRS=()
        for src in "${POSITIONAL[@]}"; do
            src=$(realpath "$src")
            PAIRS+=("$src" "${src}${SUFFIX}")
        done
    else
        [[ ${#POSITIONAL[@]} -ne 2 ]] && { echo "ERROR: expected <src_dir> <dst_dir> or use --suffix" >&2; usage; }
        PAIRS=("$(realpath "${POSITIONAL[0]}")" "$(realpath "${POSITIONAL[1]}")")
    fi

    i=0
    while [[ $i -lt ${#PAIRS[@]} ]]; do
        src_dir="${PAIRS[$i]}"
        dst_dir="${PAIRS[$((i+1))]}"
        i=$((i+2))

        echo "Verifying: $src_dir -> $dst_dir"

        if [[ ! -d "$src_dir" ]]; then
            echo "ERROR: source not found: $src_dir" >&2; OVERALL_STATUS=1; continue
        fi
        if [[ ! -d "$dst_dir" ]]; then
            echo "ERROR: destination not found: $dst_dir" >&2; OVERALL_STATUS=1; continue
        fi

        # Report files present in dst but absent from src.
        EXTRA=$(comm -13 \
            <(find "$src_dir" -type f | sed "s|^$src_dir/||" | sort) \
            <(find "$dst_dir" -type f | sed "s|^$dst_dir/||" | sort))
        if [[ -n "$EXTRA" ]]; then
            echo "EXTRA files in destination not present in source:"
            echo "$EXTRA" | sed 's/^/  /'
            OVERALL_STATUS=1
        fi

        FAIL_COUNT=$(
            find "$src_dir" -type f -print0 \
                | parallel -0 -j "$JOBS" --halt never \
                    verify_file {} "$src_dir" "$dst_dir" "$VERBOSE" \
                | grep -c "^MISSING\|^MISMATCH\|^EMBEDDED" || true
        )
        if [[ "$FAIL_COUNT" -gt 0 ]]; then
            echo "FAILED: $FAIL_COUNT file(s) did not verify"
            OVERALL_STATUS=1
        else
            echo "All files verified OK"
        fi
    done
fi

exit "$OVERALL_STATUS"
