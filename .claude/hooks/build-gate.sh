#!/bin/sh
# Stop hook: verify the app still builds before the turn ends.
#
# Runs asynchronously; on failure it re-wakes Claude with the compiler errors
# (exit 2). Exits 0 quietly when no Swift source changed since the last
# verified build, or when the build succeeds, so trivial turns pay nothing.

cd "$CLAUDE_PROJECT_DIR" 2>/dev/null || exit 0

# --- should we build? -------------------------------------------------------
# Build when Swift sources differ from the last successfully verified build,
# rather than only when the working tree is dirty. The old dirty-tree check
# silently skipped verification as soon as the changes were committed, which
# is exactly when a broken build matters most.
stamp="build/.build-gate-stamp"
current=$(find RoomLens RoomLensTests RoomLensUITests -name '*.swift' -type f \
	-exec shasum {} + 2>/dev/null | shasum | cut -d' ' -f1)

# No Swift sources at all -> nothing to verify.
[ -n "$current" ] || exit 0

if [ -f "$stamp" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$current" ]; then
	exit 0
fi

# --- pick a destination -----------------------------------------------------
# Resolve a concrete simulator UDID instead of hardcoding a device name.
# Names are ambiguous (several "iPhone 17 Pro" devices exist across runtimes)
# and a hardcoded name fails outright on any other machine.
udid=$(xcrun simctl list devices available -j 2>/dev/null | /usr/bin/python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)["devices"]
except Exception:
    sys.exit(0)
rows = []
for runtime, devs in d.items():
    if "iOS" not in runtime:
        continue
    ver = runtime.split(".iOS-")[-1].replace("-", ".")
    key = [int(p) for p in ver.split(".") if p.isdigit()]
    for x in devs:
        if "iPhone" not in x["name"]:
            continue
        rows.append([x.get("state") == "Booted", key, x["udid"]])
rows.sort(key=lambda r: (r[0], r[1]), reverse=True)
if rows:
    print(rows[0][2])
' 2>/dev/null)

if [ -n "$udid" ]; then
	destination="platform=iOS Simulator,id=$udid"
else
	# No simulator available: fall back to a generic destination so the hook
	# still type-checks the app rather than silently passing.
	destination="generic/platform=iOS Simulator"
fi

# --- build ------------------------------------------------------------------
log=$(mktemp)

# NOTE: output goes straight to a file rather than through a pipe, so the exit
# status is xcodebuild's own and no `pipefail` is needed. The previous version
# wrote `set -o pipefail 2>/dev/null; xcodebuild ...` inside an `if`, which
# discarded the pipefail result and applied to no pipeline anyway.
xcodebuild build \
	-project RoomLens.xcodeproj \
	-scheme RoomLens \
	-destination "$destination" \
	>"$log" 2>&1
status=$?

if [ "$status" -eq 0 ]; then
	mkdir -p "$(dirname "$stamp")"
	printf '%s\n' "$current" >"$stamp"
	rm -f "$log"
	exit 0
fi

echo "Build is broken after Swift changes — fix before finishing. xcodebuild output:"
grep -E 'error:|BUILD FAILED|Undefined symbol|linker command failed' "$log" | head -40
rm -f "$log"
exit 2
