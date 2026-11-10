"""Print the UDID of an available simulator.

usage: pick_simulator.py [iphone|ipad|oldest-iphone]
  iphone         newest iOS runtime, largest iPhone (default)
  ipad           newest iOS runtime, an iPad
  oldest-iphone  oldest installed iOS runtime, an iPhone; prints nothing if it is the same runtime as "iphone"
"""
import json
import re
import subprocess
import sys

mode = sys.argv[1] if len(sys.argv) > 1 else "iphone"
devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))["devices"]


def version(runtime: str) -> tuple:
    match = re.search(r"iOS-(\d+)-(\d+)", runtime)
    return (int(match.group(1)), int(match.group(2))) if match else (0, 0)


def candidates(kind: str):
    return [
        (version(runtime), "Pro Max" in d["name"] or "Pro 13" in d["name"], d["name"], d["udid"])
        for runtime, entries in devices.items()
        if "iOS" in runtime and version(runtime) >= (15, 0)
        for d in entries
        if d.get("isAvailable") and d["name"].startswith(kind)
    ]


phones = sorted(candidates("iPhone"), reverse=True)
if mode == "ipad":
    pads = sorted(candidates("iPad"), reverse=True)
    if not pads:
        sys.exit("No iPad simulator is installed on this runner.")
    print(pads[0][3])
elif mode == "oldest-iphone":
    if phones and phones[-1][0][0] != phones[0][0][0]:
        oldest = phones[-1][0]
        print(sorted(p for p in phones if p[0] == oldest)[-1][3])
else:
    if not phones:
        sys.exit("No iPhone simulator is installed on this runner.")
    print(phones[0][3])
