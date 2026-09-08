#!/bin/sh
# Format a Swift file in place after an agent edits it.
#
# Hosts and events:
#   Claude Code  PostToolUse (Edit|Write|MultiEdit)  -> tool_input.file_path
#   Cursor       afterFileEdit                       -> file_path (top level)
#   Codex        PostToolUse (Edit|Write)            -> apply_patch, no path
#
# Cursor puts file_path at the TOP LEVEL, so the original Claude-only parser
# (tool_input.file_path) returned empty and this hook did nothing. Codex's
# apply_patch payload carries patch text and no path at all. Both are handled:
# a named file is formatted directly, otherwise we fall back to formatting the
# Swift files that currently differ from HEAD.
#
# Always exits 0 so a formatting hiccup never blocks an edit.

. "$(dirname -- "$0")/_common.sh"

payload=$(cat)
file=$(printf '%s' "$payload" | hook_field file_path)

xcrun --find swift-format >/dev/null 2>&1 || exit 0

format() {
	[ -f "$1" ] || return 0
	case "$1" in
		*.swift) xcrun swift-format --in-place "$1" 2>/dev/null || true ;;
	esac
}

if [ -n "$file" ]; then
	format "$file"
	exit 0
fi

# No file path in the payload (Codex apply_patch): format what changed.
project_dir=$(hook_project_dir) || exit 0
cd "$project_dir" 2>/dev/null || exit 0

hook_dirty_swift_files | while IFS= read -r changed; do
	format "$changed"
done

exit 0
