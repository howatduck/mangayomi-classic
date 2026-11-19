#!/usr/bin/env python3
"""Inject libc++_shared.so for one ABI into an APK (Classic finalize step).

The downgrade build does not package libc++_shared.so, but the reader
decoder (libsubsampling_scale_image_view.so) needs it at runtime.

Usage: inj_libcxx.py <in.apk> <out.apk> <abi>
Env:   LIBCXX_BASE = NDK sysroot usr/lib directory that contains the
       per-arch libc++_shared.so folders (defaults to the NDK 27 sysroot
       under ANDROID_SDK_ROOT).
Exit:  prints ALREADY_PRESENT and exits 0 (no output file) when the ABI
       already ships libc++_shared.so.
"""
import os
import sys
import zipfile

apk_in, apk_out, abi = sys.argv[1], sys.argv[2], sys.argv[3]
BASE = os.environ.get(
    "LIBCXX_BASE",
    os.path.join(
        os.environ.get("ANDROID_SDK_ROOT", os.path.expanduser("~/android-sdk")),
        "ndk/27.0.12077973/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib",
    ),
)
PATHS = {
    "arm64-v8a": BASE + "/aarch64-linux-android/libc++_shared.so",
    "armeabi-v7a": BASE + "/arm-linux-androideabi/libc++_shared.so",
    "x86_64": BASE + "/x86_64-linux-android/libc++_shared.so",
    "x86": BASE + "/i686-linux-android/libc++_shared.so",
}
ARC = "lib/" + abi + "/libc++_shared.so"

zin = zipfile.ZipFile(apk_in)
if ARC in zin.namelist():
    print("ALREADY_PRESENT")
    sys.exit(0)
with zipfile.ZipFile(apk_out, "w") as zout:
    for item in zin.infolist():
        zout.writestr(item, zin.read(item.filename),
                      compress_type=item.compress_type)
    with open(PATHS[abi], "rb") as f:
        zout.writestr(ARC, f.read(), compress_type=zipfile.ZIP_DEFLATED)
print("INJECTED", ARC)
