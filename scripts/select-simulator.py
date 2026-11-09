#!/usr/bin/env python3
"""Select an installed, available iPhone on the newest installed iOS runtime."""
import json
import re
import sys

payload = json.load(sys.stdin)
candidates = []
for runtime, devices in payload.get("devices", {}).items():
    match = re.search(r"\.iOS-([0-9-]+)$", runtime)
    if not match:
        continue
    version = tuple(map(int, match.group(1).split("-")))
    for device in devices:
        if device.get("isAvailable") and device.get("name", "").startswith("iPhone"):
            candidates.append((version, device.get("state") == "Booted", device["name"], device["udid"]))
if not candidates:
    raise SystemExit("No available iPhone simulator found. Install an iOS simulator runtime in Xcode.")
print(max(candidates)[3])
