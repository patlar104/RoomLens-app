#!/bin/sh
# Shared helpers for RoomLens agent hooks.
#
# These hooks are wired into three different agent hosts (Claude Code, Cursor,
# and Codex), each of which passes a DIFFERENT JSON payload shape and sets a
# different working directory. A hook that assumes one host's shape silently
# becomes a no-op under the others — that already happened once in this repo
# (see commit ff4c0ba), so payload parsing is centralised here.
#
# Source this from a hook script:
#   . "$(dirname "$0")/_common.sh"

# --- project root -----------------------------------------------------------
# Claude Code exports CLAUDE_PROJECT_DIR. Cursor project hooks run from the
# project root. Codex runs from the session cwd, which may be a subdirectory.
# The script's own location is the only thing true under all three, so derive
# from that first and only then fall back.
hook_project_dir() {
	if [ -n "$CLAUDE_PROJECT_DIR" ] && [ -d "$CLAUDE_PROJECT_DIR" ]; then
		printf '%s\n' "$CLAUDE_PROJECT_DIR"
		return 0
	fi

	# $0 is the hook script path under every host that runs `sh <path>`.
	# CDPATH is cleared so a user's CDPATH cannot redirect the cd.
	_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." 2>/dev/null && pwd)
	if [ -n "$_dir" ] && [ -d "$_dir/RoomLens.xcodeproj" ]; then
		printf '%s\n' "$_dir"
		return 0
	fi

	_dir=$(git rev-parse --show-toplevel 2>/dev/null)
	if [ -n "$_dir" ]; then
		printf '%s\n' "$_dir"
		return 0
	fi

	return 1
}

# --- payload field extraction ----------------------------------------------
# Reads a payload on stdin, prints the requested logical field, or nothing.
#
# Known shapes for a shell command:
#   Claude Code PreToolUse ....... {"tool_input": {"command": ...}}
#   Codex       PreToolUse ....... {"tool_input": {"command": ...}}
#   Cursor      preToolUse ....... {"tool_input": {"command": ...}}
#   Cursor      beforeShellExecution {"command": ...}
#   jcode       pre_tool ......... {"command": ...}
#
# Known shapes for an edited file:
#   Claude Code PostToolUse ...... {"tool_input": {"file_path": ...}}
#   Cursor      afterFileEdit .... {"file_path": ...}
#   Codex       PostToolUse ...... {"tool_input": {"command": "<patch text>"}}
#                                  (apply_patch: no file path at all)
hook_field() {
	/usr/bin/python3 -c '
import sys, json

want = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(d, dict):
    sys.exit(0)

# Nested (Claude Code / Codex / Cursor preToolUse) or flat (Cursor
# beforeShellExecution / afterFileEdit / jcode).
inner = d.get("tool_input")
if not isinstance(inner, dict):
    inner = {}

for source in (inner, d):
    value = source.get(want)
    if isinstance(value, str) and value:
        print(value)
        sys.exit(0)
' "$1" 2>/dev/null
}

# Prints every .swift path that differs from HEAD (staged, unstaged, or
# untracked). Used as the fallback when a host does not tell us which file was
# edited — notably Codex `apply_patch`, whose payload carries the patch text
# rather than a file path.
hook_dirty_swift_files() {
	{
		git diff --name-only --diff-filter=ACM HEAD 2>/dev/null
		git ls-files --others --exclude-standard 2>/dev/null
	} | grep '\.swift$' | sort -u
}
