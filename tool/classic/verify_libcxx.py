#!/usr/bin/env python3
"""Verify libc++_shared.so coverage in a Mangayomi Classic APK.

For every ABI directory that ships the reader decoder
(libsubsampling_scale_image_view.so), a libc++_shared.so must be
present in the same directory and its ELF e_machine must match the
ABI (guards against stuffing the wrong NDK build into an ABI dir).

Usage: verify_libcxx.py <apk> [<apk> ...]
Exit code 0 when every checked ABI passes.
"""
import struct
import sys
import zipfile

MACHINES = {
    "arm64-v8a": 183,    # EM_AARCH64
    "armeabi-v7a": 40,   # EM_ARM
    "x86_64": 62,        # EM_X86_64
    "x86": 3,            # EM_386
}
DECODER = "libsubsampling_scale_image_view.so"
LIBCXX = "libc++_shared.so"


def e_machine(data: bytes) -> int:
    if len(data) < 20 or data[:4] != b"\x7fELF":
        return -1
    return struct.unpack("<H", data[18:20])[0]


def check(apk_path: str) -> bool:
    ok = True
    with zipfile.ZipFile(apk_path) as z:
        names = set(z.namelist())
        abis = sorted(
            {n.split("/")[1] for n in names
             if n.startswith("lib/") and n.count("/") >= 2}
        )
        for abi in abis:
            if f"lib/{abi}/{DECODER}" not in names:
                print(f"  {abi}: no reader decoder, skip")
                continue
            arc = f"lib/{abi}/{LIBCXX}"
            if arc not in names:
                print(f"  {abi}: MISSING {LIBCXX}")
                ok = False
                continue
            m = e_machine(z.read(arc)[:64])
            want = MACHINES.get(abi)
            if want is not None and m != want:
                print(f"  {abi}: {LIBCXX} e_machine={m}, want {want}")
                ok = False
            else:
                print(f"  {abi}: {LIBCXX} OK (e_machine={m})")
    print(("PASS " if ok else "FAIL ") + apk_path)
    return ok


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    return 0 if all(check(p) for p in sys.argv[1:]) else 1


if __name__ == "__main__":
    sys.exit(main())
