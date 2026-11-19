#!/usr/bin/env python3
"""Strip native libs of unwanted ABIs from an APK (keeps the zip otherwise
byte-identical in structure). Usage: strip_abi.py <in.apk> <out.apk> <abi1,abi2,...|all>
ABIs listed are REMOVED under lib/<abi>/."""
import sys, zipfile, os

apk_in, apk_out, remove = sys.argv[1], sys.argv[2], sys.argv[3]
remove_set = set() if remove == "all" else set(remove.split(","))
removed = 0
with zipfile.ZipFile(apk_in) as zin, zipfile.ZipFile(apk_out, "w") as zout:
    for item in zin.infolist():
        if item.filename.startswith("lib/"):
            abi = item.filename.split("/")[1] if "/" in item.filename[4:] else ""
            if abi in remove_set:
                removed += 1
                continue
        content = zin.read(item.filename)
        zi = zipfile.ZipInfo(item.filename, date_time=item.date_time)
        zi.compress_type = item.compress_type
        zi.external_attr = item.external_attr
        zout.writestr(zi, content)
print(f"stripped {removed} entries -> {apk_out} ({os.path.getsize(apk_out)} bytes)")
