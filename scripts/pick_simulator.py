"""Print the UDID of an available simulator.

usage: pick_simulator.py [iphone|ipad] [ios-major]
  iphone      newest matching iOS runtime, largest iPhone (default)
  ipad        newest matching iOS runtime, largest iPad
  ios-major   only consider simulators on this iOS major version, e.g. 18
"""
import json
import re
import subprocess
import sys

kind = "iPad" if len(sys.argv) > 1 and sys.argv[1] == "ipad" else "iPhone"
major = int(sys.argv[2]) if len(sys.argv) > 2 else None
devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))["devices"]


def version(runtime: str) -> tuple:
    match = re.search(r"iOS-(\d+)-(\d+)", runtime)
    return (int(match.group(1)), int(match.group(2))) if match else (0, 0)


candidates = sorted(
    (
        (version(runtime), "Pro Max" in d["name"] or "Pro 13" in d["name"] or "12.9" in d["name"], d["name"], d["udid"])
        for runtime, entries in devices.items()
        if "iOS" in runtime and version(runtime) >= (15, 0) and (major is None or version(runtime)[0] == major)
        for d in entries
        if d.get("isAvailable") and d["name"].startswith(kind)
    ),
    reverse=True,
)
if not candidates:
    sys.exit(f"No matching {kind} simulator is installed on this runner.")
print(candidates[0][3])
