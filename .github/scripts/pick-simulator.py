#!/usr/bin/env python3
"""Pick an iOS Simulator UDID for CI.

RoomLens targets IPHONEOS_DEPLOYMENT_TARGET = 26.0, and AGENTS.md requires the
canonical device "iPhone 17 Pro" with a fall back to another iPhone *on an
iOS 26.x (or newer) runtime*. Grepping device names out of `simctl list`
text drops the runtime headings, so a runner carrying several iOS runtimes can
yield an iPhone bound to a pre-26 runtime and every following `xcodebuild`
fails. This parses the JSON, keeps only devices on a compatible runtime, and
prints the best match's UDID to stdout (a human-readable line goes to stderr).

Exit 1 with a message if no compatible device is available.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys

MIN_IOS_MAJOR = 26


def main() -> int:
    raw = subprocess.run(
        ["xcrun", "simctl", "list", "devices", "available", "--json"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    devices_by_runtime = json.loads(raw).get("devices", {})

    best = None  # (rank_tuple, udid, name, ios_version)
    for runtime_id, devices in devices_by_runtime.items():
        match = re.search(r"iOS-(\d+)-(\d+)", runtime_id)
        if not match:
            continue
        major, minor = int(match.group(1)), int(match.group(2))
        if major < MIN_IOS_MAJOR:
            continue
        for device in devices:
            if not device.get("isAvailable", True):
                continue
            name = device.get("name", "")
            if not name.startswith("iPhone"):
                continue
            if name == "iPhone 17 Pro":
                name_rank = 3
            elif name.startswith("iPhone 17"):
                name_rank = 2
            elif "Pro" in name:
                name_rank = 1
            else:
                name_rank = 0
            rank = (name_rank, major, minor)
            if best is None or rank > best[0]:
                best = (rank, device["udid"], name, f"{major}.{minor}")

    if best is None:
        print(
            f"No available iPhone simulator on an iOS {MIN_IOS_MAJOR}+ runtime",
            file=sys.stderr,
        )
        return 1

    _, udid, name, ios_version = best
    print(f"Selected {name} on iOS {ios_version} (udid {udid})", file=sys.stderr)
    print(udid)
    return 0


if __name__ == "__main__":
    sys.exit(main())
