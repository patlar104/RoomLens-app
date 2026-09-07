#!/bin/sh
# PreToolUse hook (git commit): block the commit when a staged Swift file fails
# `swift-format lint`. The format-on-save hook only touches files Claude edited;
# this covers everything in the staged tree. Exits 0 when clean, when nothing
# Swift is staged, or when swift-format is unavailable.

cd "$CLAUDE_PROJECT_DIR" 2>/dev/null || exit 0

files=$(git diff --cached --name-only --diff-filter=ACM | grep '\.swift$')
[ -n "$files" ] || exit 0

xcrun --find swift-format >/dev/null 2>&1 || exit 0

out=$(printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 xcrun swift-format lint --strict 2>&1)
[ -z "$out" ] && exit 0

echo "swift-format lint failed on staged files — run 'xcrun swift-format --in-place' and re-stage:" >&2
printf '%s\n' "$out" >&2
exit 2
