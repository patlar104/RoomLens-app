#!/bin/sh
# Block a commit when a staged Swift file fails `swift-format lint`.
#
# The format-on-save hook only touches files the agent edited; this covers
# everything in the staged tree. Exits 0 when clean, when nothing Swift is
# staged, or when swift-format is unavailable.
#
# Hosts and events:
#   Claude Code  PreToolUse (Bash, `git commit`)
#   Cursor       beforeShellExecution (matcher: git commit)
#   Codex        PreToolUse (Bash)
#
# Claude Code filters by an `if` condition in settings.json and Cursor by a
# matcher, but neither is guaranteed to be the only gate, so the command check
# is repeated here. That keeps the hook correct even when a host runs it for
# every shell command.

. "$(dirname -- "$0")/_common.sh"

payload=$(cat)
command=$(printf '%s' "$payload" | hook_field command)

# Only gate actual commits. A missing command means the host did not give us
# one to inspect, in which case fall through and lint anyway.
if [ -n "$command" ]; then
	printf '%s' "$command" | grep -Eq 'git +([-a-zA-Z0-9=/. ]+ +)?commit' || exit 0
fi

project_dir=$(hook_project_dir) || exit 0
cd "$project_dir" 2>/dev/null || exit 0

files=$(git diff --cached --name-only --diff-filter=ACM | grep '\.swift$')
[ -n "$files" ] || exit 0

xcrun --find swift-format >/dev/null 2>&1 || exit 0

out=$(printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 xcrun swift-format lint --strict 2>&1)
[ -z "$out" ] && exit 0

message="swift-format lint failed on staged files — run 'xcrun swift-format --in-place' and re-stage:
$out"

printf '{"permission":"deny","user_message":%s,"agent_message":%s}\n' \
	"$(printf '%s' "$message" | /usr/bin/python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')" \
	"$(printf '%s' "$message" | /usr/bin/python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')"
printf '%s\n' "$message" >&2
exit 2
