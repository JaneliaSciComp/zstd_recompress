#!/usr/bin/env bash
# Recompress zstd-compressed files to include the uncompressed content size in the frame header.
# Files that already have content size recorded are skipped.
#
# In-place mode (default): recompression is done atomically via a temp file + rename.
# Mirror mode (-s/--suffix): output is written to a new directory tree; non-zstd files are copied.
# Manifest (-m/--manifest): write a XXH64 checksum of every file's decompressed content to a file.

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
Usage: $0 [OPTIONS] <directory> [<directory> ...]

Options:
  -j, --jobs N       Parallel jobs (default: number of CPU cores)
  -l, --level N      zstd compression level 1-22 (default: 3)
  -s, --suffix SUF   Write output to a mirrored directory tree instead of modifying
                     files in place. Each source directory <dir> is mirrored to
                     <dir><SUF>. Non-zstd files are copied; zstd files without
                     content size are recompressed; zstd files that already have
                     content size are copied unchanged.
  -m, --manifest F   Write a XXH64 checksum manifest of all files' decompressed
                     content to file F. Paths in the manifest are relative to each
                     source directory root. Existing file is overwritten.
  -n, --dry-run      Print what would be done without changing or creating anything
  -v, --verbose      Print each file as it is processed
  -h, --help         Show this help

Examples:
  # In-place recompression
  $0 /path/to/data.zarr

  # Mirror to data.zarr.recompressed, leave original untouched
  $0 --suffix .recompressed /path/to/data.zarr

  # Mirror and write a checksum manifest
  $0 --suffix .recompressed --manifest data.xxh64 /path/to/data.zarr

  # Preview what would happen
  $0 --suffix .recompressed --dry-run /path/to/data.zarr
EOF
    exit 1
}

JOBS=$(nproc)
LEVEL=3
SUFFIX=""
MANIFEST=""
DRY_RUN=false
VERBOSE=false
DIRS=()

while [[ $# -gt 0 ]]; do
    case $1 in
        -j|--jobs)     JOBS="$2";     shift 2 ;;
        -l|--level)    LEVEL="$2";    shift 2 ;;
        -s|--suffix)   SUFFIX="$2";   shift 2 ;;
        -m|--manifest) MANIFEST="$2"; shift 2 ;;
        -n|--dry-run)  DRY_RUN=true;  shift   ;;
        -v|--verbose)  VERBOSE=true;  shift   ;;
        -h|--help)     usage ;;
        -*)            echo "Unknown option: $1" >&2; usage ;;
        *)             DIRS+=("$1");  shift   ;;
    esac
done

[[ ${#DIRS[@]} -eq 0 ]] && usage

# ---------------------------------------------------------------------------
# is_zstd FILE       — exit 0 if FILE is a valid zstd stream
is_zstd() {
    zstd -l "$1" &>/dev/null
}
export -f is_zstd

# has_content_size FILE — exit 0 if FILE is zstd AND content size is stored
has_content_size() {
    local info
    info=$(zstd -l "$1" 2>/dev/null) || return 1
    # The data row's 4th field is the uncompressed size when present.
    echo "$info" | awk 'NR==2 { exit ($4 ~ /^[0-9]/) ? 0 : 1 }'
}
export -f has_content_size

# append_manifest HASH REL MANIFEST — safely append one entry (parallel-safe via flock)
append_manifest() {
    local hash="$1" rel="$2" manifest="$3"
    (
        flock 9
        printf '%s  %s\n' "$hash" "$rel" >> "$manifest"
    ) 9>"${manifest}.lock"
}
export -f append_manifest

# xxh64 FILE_OR_STDIN — print only the hash, no filename
xxh64_of_file()  { xxh64sum "$1"     | awk '{print $1}'; }
xxh64_of_stdin() { xxh64sum          | awk '{print $1}'; }
export -f xxh64_of_file xxh64_of_stdin

# ---------------------------------------------------------------------------
# process_inplace FILE SRC_DIR LEVEL DRY_RUN VERBOSE MANIFEST
process_inplace() {
    local f="$1" src_dir="$2" level="$3" dry_run="$4" verbose="$5" manifest="$6"
    local rel="${f#"$src_dir"/}"

    if has_content_size "$f"; then
        [[ "$verbose" == true ]] && echo "skip (already has content size): $f"
        if [[ -n "$manifest" && "$dry_run" != true ]]; then
            local hash
            hash=$(zstd -d --stdout "$f" | xxh64_of_stdin)
            append_manifest "$hash" "$rel" "$manifest"
        fi
        return 0
    fi

    if ! is_zstd "$f"; then
        [[ "$verbose" == true ]] && echo "skip (not zstd): $f"
        if [[ -n "$manifest" && "$dry_run" != true ]]; then
            local hash
            hash=$(xxh64_of_file "$f")
            append_manifest "$hash" "$rel" "$manifest"
        fi
        return 0
    fi

    if [[ "$dry_run" == true ]]; then
        echo "would recompress (in place): $f"
        return 0
    fi
    [[ "$verbose" == true ]] && echo "recompressing (in place): $f"

    local tmp_raw tmp_out
    tmp_raw=$(mktemp "${f}.raw.XXXXXX")
    tmp_out=$(mktemp "${f}.tmp.XXXXXX")
    if zstd -d -o "$tmp_raw" -f --no-progress "$f" \
        && zstd -"$level" --content-size -o "$tmp_out" -f --no-progress "$tmp_raw"; then
        if [[ -n "$manifest" ]]; then
            local hash
            hash=$(xxh64_of_file "$tmp_raw")
            append_manifest "$hash" "$rel" "$manifest"
        fi
        rm -f "$tmp_raw"
        mv "$tmp_out" "$f"
    else
        rm -f "$tmp_raw" "$tmp_out"
        echo "ERROR: failed to recompress $f" >&2
        return 1
    fi
}
export -f process_inplace

# ---------------------------------------------------------------------------
# process_mirror FILE SRC_DIR DST_DIR LEVEL DRY_RUN VERBOSE MANIFEST
process_mirror() {
    local f="$1" src_dir="$2" dst_dir="$3" level="$4" dry_run="$5" verbose="$6" manifest="$7"
    local rel="${f#"$src_dir"/}"
    local dst="$dst_dir/$rel"

    if [[ "$dry_run" != true ]]; then
        mkdir -p "$(dirname "$dst")"
    fi

    if ! is_zstd "$f"; then
        if [[ "$dry_run" == true ]]; then
            echo "would copy (not zstd): $f -> $dst"
        else
            [[ "$verbose" == true ]] && echo "copy (not zstd): $f -> $dst"
            cp -p "$f" "$dst"
            if [[ -n "$manifest" ]]; then
                local hash
                hash=$(xxh64_of_file "$f")
                append_manifest "$hash" "$rel" "$manifest"
            fi
        fi
        return 0
    fi

    if has_content_size "$f"; then
        if [[ "$dry_run" == true ]]; then
            echo "would copy (already has content size): $f -> $dst"
        else
            [[ "$verbose" == true ]] && echo "copy (already has content size): $f -> $dst"
            cp -p "$f" "$dst"
            if [[ -n "$manifest" ]]; then
                local hash
                hash=$(zstd -d --stdout "$f" | xxh64_of_stdin)
                append_manifest "$hash" "$rel" "$manifest"
            fi
        fi
        return 0
    fi

    if [[ "$dry_run" == true ]]; then
        echo "would recompress: $f -> $dst"
        return 0
    fi
    [[ "$verbose" == true ]] && echo "recompressing: $f -> $dst"

    local tmp_raw tmp_out
    tmp_raw=$(mktemp "${dst}.raw.XXXXXX")
    tmp_out=$(mktemp "${dst}.tmp.XXXXXX")
    if zstd -d -o "$tmp_raw" -f --no-progress "$f" \
        && zstd -"$level" --content-size -o "$tmp_out" -f --no-progress "$tmp_raw"; then
        if [[ -n "$manifest" ]]; then
            local hash
            hash=$(xxh64_of_file "$tmp_raw")
            append_manifest "$hash" "$rel" "$manifest"
        fi
        rm -f "$tmp_raw"
        mv "$tmp_out" "$dst"
    else
        rm -f "$tmp_raw" "$tmp_out"
        echo "ERROR: failed to recompress $f -> $dst" >&2
        return 1
    fi
}
export -f process_mirror

# ---------------------------------------------------------------------------
# Resolve each source directory to an absolute path so prefix-stripping is
# unambiguous regardless of how the user specified the path.
ABS_DIRS=()
for d in "${DIRS[@]}"; do
    ABS_DIRS+=("$(realpath "$d")")
done

# Truncate manifest now (before parallel workers start appending).
if [[ -n "$MANIFEST" && "$DRY_RUN" != true ]]; then
    : > "$MANIFEST"
    rm -f "${MANIFEST}.lock"
fi

if [[ -z "$SUFFIX" ]]; then
    # ---- In-place mode ----
    for src_dir in "${ABS_DIRS[@]}"; do
        find "$src_dir" -type f -print0 \
            | parallel -0 -j "$JOBS" --halt soon,fail=1 \
                process_inplace {} "$src_dir" "$LEVEL" "$DRY_RUN" "$VERBOSE" "$MANIFEST"
    done
else
    # ---- Mirror mode ----
    for src_dir in "${ABS_DIRS[@]}"; do
        dst_dir="${src_dir}${SUFFIX}"

        if [[ "$DRY_RUN" != true ]]; then
            mkdir -p "$dst_dir"
        fi

        find "$src_dir" -type f -print0 \
            | parallel -0 -j "$JOBS" --halt soon,fail=1 \
                process_mirror {} "$src_dir" "$dst_dir" "$LEVEL" "$DRY_RUN" "$VERBOSE" "$MANIFEST"
    done
fi

# Sort the manifest for reproducibility (parallel workers append in arbitrary order).
if [[ -n "$MANIFEST" && "$DRY_RUN" != true && -s "$MANIFEST" ]]; then
    sort -k2 "$MANIFEST" -o "$MANIFEST"
    rm -f "${MANIFEST}.lock"
fi

echo "Done."
