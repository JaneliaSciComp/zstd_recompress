# zstd_recompress

Scripts for recompressing zstd-compressed files so that each frame includes
the uncompressed content size in its header, and for verifying that the
recompressed data matches the original.

## Background

The [zstd frame format](https://github.com/facebook/zstd/blob/dev/doc/zstd_compression_format.md)
has an optional `Frame_Content_Size` field that records the uncompressed size
of the data directly in the frame header. When this field is present, tools and
libraries can:

- allocate the exact output buffer size before decompressing
- report the uncompressed size without a full scan of the file (`zstd -l`)
- decompress in a single pass without resizing buffers

Some Zarr writers (and other software) compress chunks with zstd but omit this
field. The symptom is a blank `Uncompressed` column and `None` in the `Check`
column of `zstd -l` output:

```
$ zstd -l chunk_file
Frames  Skips  Compressed  Uncompressed  Ratio  Check  Filename
     1      0     621 KiB                        None  chunk_file
```

After recompression both fields are populated:

```
$ zstd -l chunk_file
Frames  Skips  Compressed  Uncompressed  Ratio  Check  Filename
     1      0     622 KiB     1.000 MiB  1.647  XXH64  chunk_file
```

The `XXH64` entry in the `Check` column is an integrity checksum embedded in
the frame header. It stores the lower 32 bits of the XXH64 hash of the
uncompressed content and is validated automatically by `zstd -t` and during
decompression.

## Environment

A [pixi](https://pixi.sh) environment is provided with pinned versions of all
required tools. Both scripts activate it automatically at startup via
`pixi shell-hook`, so no manual setup is needed beyond having `pixi` on your
PATH.

```
pixi.toml   ← declares zstd and xxhash dependencies
```

Tools provided by the environment:

| Tool | Purpose |
|------|---------|
| `zstd` | Compression, decompression, frame inspection |
| `xxh64sum` | Full 64-bit XXH64 checksum of raw (decompressed) data |
| `xxh32sum` | XXH32 checksum (different algorithm; not compatible with the zstd embedded checksum) |

Note: the zstd frame stores only the **lower 32 bits** of the XXH64 hash.
`xxh64sum` produces the full 64-bit value, which is a strictly stronger check
than what is embedded in the frame.

## `zstd_recompress.sh`

Walks a directory tree, finds zstd-compressed files that lack the content size
field, and recompresses them. Optionally writes a XXH64 checksum manifest of
all files' decompressed content.

### Usage

```
zstd_recompress.sh [OPTIONS] <directory> [<directory> ...]
```

### Options

| Flag | Default | Description |
|------|---------|-------------|
| `-j, --jobs N` | all cores | Number of parallel jobs |
| `-l, --level N` | `3` | zstd compression level (1–22) |
| `-s, --suffix SUF` | *(in-place)* | Mirror output to `<dir><SUF>` instead of modifying files in place |
| `-m, --manifest F` | *(none)* | Write a XXH64 checksum manifest of all files' decompressed content to `F` |
| `-n, --dry-run` | | Print what would be done without making any changes |
| `-v, --verbose` | | Print each file as it is processed |
| `-h, --help` | | Show help |

### In-place mode (default)

Recompresses zstd files that are missing the content size field directly inside
the source directory tree. Files that already have the field set are skipped.
Each file is written to a temporary path beside the original and renamed
atomically, so a failure leaves the original intact.

```bash
./zstd_recompress.sh /path/to/data.zarr
```

### Mirror mode (`--suffix`)

Writes output to a new directory tree that mirrors the source. The original
directory is never modified. Each source directory `<dir>` is mirrored to
`<dir><suffix>`. Non-zstd files are copied over, so the output directory is a
fully self-contained copy.

```bash
./zstd_recompress.sh --suffix .recompressed /path/to/data.zarr
# Output: /path/to/data.zarr.recompressed/
```

Per-file behaviour in mirror mode:

| File type | Action |
|-----------|--------|
| zstd, content size missing | Recompress → destination |
| zstd, content size already present | Copy unchanged → destination |
| Not zstd | `cp -p` → destination |

### Checksum manifest (`--manifest`)

Writes a XXH64 checksum manifest recording the hash of every file's
**decompressed** content. Paths in the manifest are relative to the source
directory root. The manifest is sorted by path for reproducibility.

```bash
./zstd_recompress.sh --suffix .recompressed --manifest data.xxh64 /path/to/data.zarr
```

Example manifest:

```
7eefd5bb94d3b5fc  raw/s3/20/0/0
1a776909d6586cb9  raw/s3/20/1/0
c19616feccb45103  .zarray
```

For zstd files being recompressed, the hash is computed from the temporary
decompressed file that is already on disk, so it adds no extra I/O. For files
that are copied unchanged (already have content size or are not zstd), one
decompression pass is required to compute the hash.

The manifest can be passed to `zstd_verify.sh` to verify the mirror without
needing to access the original source.

### Previewing changes

`--dry-run` works in both modes and shows the full `src -> dst` path in mirror
mode without creating or modifying any files. The manifest is not written in
dry-run mode.

```bash
./zstd_recompress.sh --dry-run /path/to/data.zarr
./zstd_recompress.sh --suffix .recompressed --dry-run /path/to/data.zarr
```

### Controlling parallelism

By default all available CPU cores are used. On a shared cluster node you may
want to limit this:

```bash
./zstd_recompress.sh -j 8 /path/to/data.zarr
```

## `zstd_verify.sh`

Verifies that files in a mirrored directory match their originals. Two modes
are available.

### Usage

```
# Direct comparison (requires access to source)
zstd_verify.sh [OPTIONS] <src_dir> <dst_dir>
zstd_verify.sh [OPTIONS] --suffix SUF <src_dir> [<src_dir> ...]

# Manifest-based verification (no source access needed)
zstd_verify.sh [OPTIONS] --manifest FILE <dst_dir>
zstd_verify.sh [OPTIONS] --manifest FILE --suffix SUF <src_dir> [<src_dir> ...]
```

### Options

| Flag | Default | Description |
|------|---------|-------------|
| `-j, --jobs N` | all cores | Number of parallel jobs |
| `-m, --manifest F` | *(none)* | Verify against a manifest produced by `zstd_recompress.sh --manifest` |
| `-s, --suffix SUF` | | Derive each `dst_dir` as `<src_dir><SUF>` |
| `-v, --verbose` | | Print each file as it is verified |
| `-h, --help` | | Show help |

Exits with status `0` if all files verify, `1` if any mismatch, missing file,
or embedded checksum failure is detected.

### Direct comparison mode

Decompresses both source and destination files on the fly and compares their
full 64-bit XXH64 hashes. Also runs `zstd -t` on every zstd file in the
destination to validate the embedded frame checksum. Does not require a
manifest but requires read access to both directories.

```bash
./zstd_verify.sh --suffix .recompressed /path/to/data.zarr
./zstd_verify.sh /path/to/data.zarr /path/to/data.zarr.recompressed
```

### Manifest-based verification

Verifies the destination against a manifest written by
`zstd_recompress.sh --manifest`. The source directory is not accessed.
For each manifest entry the corresponding file in the destination is
decompressed and its XXH64 hash is compared to the recorded value. `zstd -t`
is also run on every zstd destination file.

```bash
./zstd_verify.sh --manifest data.xxh64 /path/to/data.zarr.recompressed
./zstd_verify.sh --manifest data.xxh64 --suffix .recompressed /path/to/data.zarr
```

## How recompression works

Because zstd cannot write the content size field when reading from a pipe
(the total size is not known until decompression is complete), recompression is
done in two steps:

1. Decompress the source file to a temporary file.
2. Recompress from the temporary file using `zstd --content-size`.

In in-place mode the final compressed file is written to a second temporary
path and then renamed over the original, so no window exists where a partial
write is visible as the real file. Both temporary files are cleaned up on
success or failure.

## Checksums and the zstd frame format

The zstd frame format stores a 32-bit content checksum field containing the
**lower 32 bits** of the XXH64 hash of the uncompressed data. This is what
`zstd -l -v` shows as `Check: XXH64 94d3b5fc` and what `zstd -t` validates.

The manifest produced by `--manifest` stores the **full 64-bit** XXH64 hash
(`7eefd5bb94d3b5fc`) computed by `xxh64sum`. This is a strictly stronger
integrity record than the embedded frame checksum, and is sufficient to detect
any corruption or divergence between the original and recompressed data.

Note that `xxh32sum` (XXH32 algorithm) produces a different value and is
**not** compatible with the zstd embedded checksum.
