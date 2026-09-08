#!/bin/sh
# Stop hook: verify the app still builds before the turn ends.
#
# On failure it asks the agent to keep going, feeding back the compiler errors.
# Exits 0 quietly when no Swift source changed since the last verified build,
# or when the build succeeds, so trivial turns pay nothing.
#
# Hosts and events:
#   Claude Code  Stop  -> exit 2 + stderr re-wakes the agent
#   Cursor       stop  -> {"decision":"block","reason":...} becomes a follow-up
#   Codex        Stop  -> {"decision":"block","reason":...} continues the turn
#
# All three honour exit code 2, and both Cursor and Codex accept the flat
# {"decision":"block","reason":...} shape, so emitting the JSON on stdout and
# the same text on stderr covers every host. Each host caps automatic
# continuations on its own (Cursor `loop_limit`, Codex `stop_hook_active`), so
# a persistently broken build cannot loop forever.

. "$(dirname -- "$0")/_common.sh"

# Stop payloads carry no field we need, but draining stdin avoids a broken pipe
# on the host side.
cat >/dev/null 2>&1

project_dir=$(hook_project_dir) || exit 0
cd "$project_dir" 2>/dev/null || exit 0

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
# status is xcodebuild's own and no `pipefail` is needed.
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

errors=$(grep -E 'error:|BUILD FAILED|Undefined symbol|linker command failed' "$log" | head -40)
rm -f "$log"

message="Build is broken after Swift changes — fix before finishing. xcodebuild output:
$errors"

printf '{"decision":"block","reason":%s}\n' \
	"$(printf '%s' "$message" | /usr/bin/python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')"
printf '%s\n' "$message" >&2
exit 2
