#!/usr/bin/env python3
"""Classic: patch libisar.so inside a built APK to bypass the libmdbx
kernel-version gate (libmdbx requires Linux >= 3.16 and returns
MDBX_INCOMPATIBLE from mdbx_env_create on older kernels).

Target device (Verizon Ellipsis 8 HD) runs kernel 3.10.84, so Isar could
not open any database and Mangayomi showed "Failed to start Mangayomi".

The gate lives in mdbx_env_create: two conditional branches jump to the
MDBX_INCOMPATIBLE path when the cached OS-version fields fail the check.
Both branches are NOP-ed out (verified byte patterns for
isar_community_flutter_libs 3.4.1, arm64 libisar.so):

  VA 0xE4D4C (file off 0xE0D4C): b.lo -> NOP   (43 08 00 54 -> 1f 20 03 d5)
  VA 0xE4D78 (file off 0xE0D78): b.ls -> NOP   (c9 08 00 54 -> 1f 20 03 d5)

Usage: patch_isar_kernel_gate.py <in.apk> <out.apk>
Afterwards: zipalign + re-sign (debug key is fine for Classic use).
Offsets are version-specific: the script asserts the original bytes and
aborts if they do not match.
"""
import sys, zipfile, os

PATCHES = [(0xE0D4C, bytes.fromhex("43080054")), (0xE0D78, bytes.fromhex("c9080054"))]
NOP = bytes.fromhex("1f2003d5")

def main() -> None:
    apk_in, apk_out = sys.argv[1], sys.argv[2]
    with zipfile.ZipFile(apk_in) as z:
        name = [n for n in z.namelist() if n.endswith("arm64-v8a/libisar.so")][0]
        data = bytearray(z.read(name))
    for off, expect in PATCHES:
        got = bytes(data[off:off+4])
        assert got == expect, f"offset {off:#x}: got {got.hex()}, expected {expect.hex()}"
        data[off:off+4] = NOP
        print(f"patched {off:#x} -> NOP")
    with zipfile.ZipFile(apk_in) as zin, zipfile.ZipFile(apk_out, "w") as zout:
        for item in zin.infolist():
            content = zin.read(item.filename)
            if item.filename == name:
                content = bytes(data)
            zi = zipfile.ZipInfo(item.filename, date_time=item.date_time)
            zi.compress_type = item.compress_type
            zi.external_attr = item.external_attr
            zout.writestr(zi, content)
    print("written:", apk_out, os.path.getsize(apk_out))

if __name__ == "__main__":
    main()
