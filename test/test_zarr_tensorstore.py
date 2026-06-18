"""
Demonstrates the TensorStore/zarr-python/numcodecs incompatibility and the fix.

TensorStore writes Zarr v2 arrays with zstd compression using the streaming
API, which produces frames without the Frame_Content_Size field.  numcodecs
< 0.16.2 (required by zarr-python 2.x) cannot decompress such frames and
raises "Zstd decompression error: invalid input data".

Running zstd_recompress.sh on the array fixes the frames in place, after
which zarr-python 2.x can open and read the array correctly.

References:
  https://github.com/google/tensorstore/issues/182
  https://github.com/zarr-developers/numcodecs/pull/707
"""

import asyncio
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import numcodecs
import tensorstore as ts
import zarr

SCRIPT_DIR = Path(__file__).parent.parent
RECOMPRESS = SCRIPT_DIR / "zstd_recompress.sh"

PASS = 0
FAIL = 0


def passed(msg: str) -> None:
    global PASS
    print(f"  PASS: {msg}")
    PASS += 1


def failed(msg: str) -> None:
    global FAIL
    print(f"  FAIL: {msg}")
    FAIL += 1


# ---------------------------------------------------------------------------
print("=== Environment ===")
print(f"  zarr       {zarr.__version__}")
print(f"  numcodecs  {numcodecs.__version__}")
print(f"  tensorstore available: {ts is not None}")
print()

# ---------------------------------------------------------------------------
print("=== Setup: write a Zarr v2 array with TensorStore (zstd, no content size) ===")

tmpdir = Path(tempfile.mkdtemp())
zarr_path = tmpdir / "test.zarr"

try:
    async def write_array():
        store = await ts.open(
            {
                "driver": "zarr",
                "kvstore": {"driver": "file", "path": str(zarr_path)},
                "metadata": {
                    "dtype": "<u1",
                    "shape": [64, 64, 64],
                    "chunks": [32, 32, 32],
                    "compressor": {"id": "zstd", "level": 3},
                },
                "create": True,
                "delete_existing": True,
            }
        )
        await store[...].write(1)

    asyncio.run(write_array())
    passed("TensorStore wrote Zarr v2 array with zstd compression")
except Exception as e:
    failed(f"TensorStore write failed: {e}")
    sys.exit(1)

# Confirm the chunks lack content size.
chunk_files = list(zarr_path.glob("**/*"))
chunk_files = [f for f in chunk_files if f.is_file() and not f.name.startswith(".")]
no_size_count = 0
for chunk in chunk_files:
    result = subprocess.run(
        ["zstd", "-l", str(chunk)], capture_output=True, text=True
    )
    if result.returncode == 0:
        fields = result.stdout.splitlines()[1].split()
        # Field $5 (index 4) is the uncompressed size when present
        if len(fields) < 5 or not fields[4][0].isdigit():
            no_size_count += 1

if no_size_count == len(chunk_files):
    passed(f"All {no_size_count} chunk(s) lack content size (as expected from TensorStore)")
else:
    failed(f"Only {no_size_count}/{len(chunk_files)} chunks lack content size")

# ---------------------------------------------------------------------------
print()
print("=== Step 1: attempt to open with zarr-python (before recompression) ===")

try:
    z = zarr.open(str(zarr_path), mode="r")
    _ = z[0, 0, 0]
    failed(
        f"zarr-python {zarr.__version__} / numcodecs {numcodecs.__version__} "
        "unexpectedly succeeded reading TensorStore output"
    )
except Exception as e:
    if "decompression" in str(e).lower() or "invalid" in str(e).lower():
        passed(
            f"zarr-python {zarr.__version__} / numcodecs {numcodecs.__version__} "
            f"correctly failed: {e}"
        )
    else:
        failed(f"zarr-python failed for an unexpected reason: {e}")

# ---------------------------------------------------------------------------
print()
print("=== Step 2: recompress with zstd_recompress.sh ===")

result = subprocess.run(
    ["bash", str(RECOMPRESS), "--jobs", "4", str(zarr_path)],
    capture_output=True,
    text=True,
)
if result.returncode == 0:
    passed("zstd_recompress.sh completed successfully")
else:
    failed(f"zstd_recompress.sh failed:\n{result.stderr}")
    sys.exit(1)

# Confirm all chunks now have content size.
with_size_count = 0
for chunk in chunk_files:
    result = subprocess.run(
        ["zstd", "-l", str(chunk)], capture_output=True, text=True
    )
    if result.returncode == 0:
        fields = result.stdout.splitlines()[1].split()
        if len(fields) >= 5 and fields[4][0].isdigit():
            with_size_count += 1

if with_size_count == len(chunk_files):
    passed(f"All {with_size_count} chunk(s) now have content size")
else:
    failed(f"Only {with_size_count}/{len(chunk_files)} chunks have content size after recompression")

# ---------------------------------------------------------------------------
print()
print("=== Step 3: open with zarr-python (after recompression) ===")

try:
    z = zarr.open(str(zarr_path), mode="r")
    val = z[0, 0, 0]
    passed(
        f"zarr-python {zarr.__version__} / numcodecs {numcodecs.__version__} "
        f"successfully read recompressed array (value={val})"
    )
except Exception as e:
    failed(f"zarr-python failed after recompression: {e}")

# ---------------------------------------------------------------------------
finally_cleanup = True
try:
    shutil.rmtree(tmpdir)
except Exception:
    finally_cleanup = False

print()
print("=== Results ===")
print(f"  Passed: {PASS}")
print(f"  Failed: {FAIL}")
print()
if FAIL == 0:
    print("All tests passed.")
else:
    print("Some tests FAILED.")
    sys.exit(1)
