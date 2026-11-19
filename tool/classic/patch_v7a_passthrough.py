#!/usr/bin/env python3
"""Passthrough for the armv7 split: the libmdbx kernel-gate offsets for the
32-bit libisar.so have NOT been located yet, so this build keeps the stock
gate (requires Linux kernel >= 3.16). Copies in.apk -> out.apk unchanged."""
import sys, shutil
print("WARNING: armv7 Isar kernel gate NOT patched (stock >=3.16 gate intact)")
shutil.copyfile(sys.argv[1], sys.argv[2])
print("written:", sys.argv[2])
