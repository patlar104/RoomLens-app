#!/bin/bash
# Build, install, and launch RoomLens in the iOS Simulator using Apple's own
# tooling (xcodebuild + xcrun simctl + Simulator.app).
#
# This is the reliable path to see the app run while the Claude desktop app's
# in-panel iOS Simulator is unavailable. It does not depend on that feature.
#
# Usage:
#   Scripts/sim.sh                 build, boot a sim, install, launch
#   Scripts/sim.sh --shot          same, then save a screenshot to build/last-shot.png
#   Scripts/sim.sh --device NAME   target a specific simulator by name
#
set -euo pipefail

cd "$(dirname "$0")/.."

SCHEME="RoomLens"
BUNDLE_ID="com.patrick.RoomLens"
DERIVED="build"
DEVICE_NAME=""
WANT_SHOT=0

while [ $# -gt 0 ]; do
	case "$1" in
		--shot) WANT_SHOT=1 ;;
		--device) DEVICE_NAME="${2:-}"; shift ;;
		*) echo "unknown arg: $1" >&2; exit 2 ;;
	esac
	shift
done

# --- pick and boot a simulator ---------------------------------------------
# Build an ordered candidate list (already-booted first, then newest iOS
# runtime first) and boot the first one that actually comes up. This skips a
# runtime whose disk image is registered but unavailable (e.g. a freshly added
# iOS 27 runtime that CoreSimulator can't mount yet).
list_candidates() {
	# emits: "<udid>|<label>" per line, already-booted first then newest iOS first
	xcrun simctl list devices available -j | /usr/bin/python3 -c '
import sys, json
d = json.load(sys.stdin)["devices"]
want = sys.argv[1] if len(sys.argv) > 1 else ""
rows = []
for runtime, devs in d.items():
    if "iOS" not in runtime:
        continue
    ver = runtime.split(".iOS-")[-1].replace("-", ".")
    key = [int(p) for p in ver.split(".") if p.isdigit()]
    for x in devs:
        if "iPhone" not in x["name"]:
            continue
        if want and x["name"] != want:
            continue
        booted = x.get("state") == "Booted"
        rows.append([booted, key, x["udid"], x["name"] + " / iOS " + ver])
rows.sort(key=lambda r: (r[0], r[1]), reverse=True)
for r in rows:
    print(r[2] + "|" + r[3])
' "$DEVICE_NAME"
}

device_state() {
	xcrun simctl list devices -j | /usr/bin/python3 -c \
		'import sys,json;u=sys.argv[1];print(next((x["state"] for r in json.load(sys.stdin)["devices"].values() for x in r if x["udid"]==u),""))' "$1"
}

CANDIDATES=$(list_candidates)
[ -n "$CANDIDATES" ] || { echo "no usable iPhone simulator found" >&2; exit 1; }

UDID=""; DEV_LABEL=""
while IFS= read -r row; do
	[ -n "$row" ] || continue
	cand_udid="${row%%|*}"; cand_label="${row#*|}"
	if [ "$(device_state "$cand_udid")" = "Booted" ]; then
		UDID="$cand_udid"; DEV_LABEL="$cand_label"; break
	fi
	echo ">> trying $cand_label …"
	if xcrun simctl boot "$cand_udid" 2>/dev/null && xcrun simctl bootstatus "$cand_udid" -b >/dev/null 2>&1; then
		UDID="$cand_udid"; DEV_LABEL="$cand_label"; break
	fi
	xcrun simctl shutdown "$cand_udid" >/dev/null 2>&1 || true
	echo "   …skipped (runtime unavailable)"
done <<EOF
$CANDIDATES
EOF
[ -n "$UDID" ] || { echo "could not boot any iPhone simulator" >&2; exit 1; }
echo ">> simulator: $DEV_LABEL  ($UDID)"

# --- build ---------------------------------------------------------------------
echo ">> building ($SCHEME)…"
set -o pipefail
xcodebuild build \
	-project RoomLens.xcodeproj \
	-scheme "$SCHEME" \
	-configuration Debug \
	-destination "platform=iOS Simulator,id=$UDID" \
	-derivedDataPath "$DERIVED" \
	| xcbeautify

APP_PATH="$DERIVED/Build/Products/Debug-iphonesimulator/$SCHEME.app"
[ -d "$APP_PATH" ] || { echo "built app not found at $APP_PATH" >&2; exit 1; }

# Open a GUI so you can watch. Xcode 27 removed Simulator.app and replaced it
# with Device Hub; older Xcode still has Simulator.app. Headless flow below
# works regardless of which (or neither) is present.
DEV_DIR="$(dirname "$(xcode-select -p)")"   # .../Xcode*.app/Contents
if [ -d "$DEV_DIR/Applications/DeviceHub.app" ]; then
	open "$DEV_DIR/Applications/DeviceHub.app" || true
elif [ -d "$DEV_DIR/Developer/Applications/Simulator.app" ]; then
	open "$DEV_DIR/Developer/Applications/Simulator.app" --args -CurrentDeviceUDID "$UDID" || true
elif open -Ra Simulator >/dev/null 2>&1; then
	open -a Simulator --args -CurrentDeviceUDID "$UDID" || true
else
	echo ">> note: no simulator GUI found — running headless. Use --shot to capture the screen."
fi

echo ">> installing…"
xcrun simctl install "$UDID" "$APP_PATH"
echo ">> launching ${BUNDLE_ID}"
xcrun simctl launch "$UDID" "$BUNDLE_ID"

if [ "$WANT_SHOT" -eq 1 ]; then
	mkdir -p "$DERIVED"
	sleep 2
	xcrun simctl io "$UDID" screenshot "$DERIVED/last-shot.png"
	echo ">> screenshot: $DERIVED/last-shot.png"
fi

echo ">> done."
