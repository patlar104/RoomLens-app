#!/bin/sh
# PostToolUse hook: format a Swift file in place after Claude edits it.
# Reads the hook JSON payload on stdin, extracts tool_input.file_path,
# and runs `xcrun swift-format` only when that file is a .swift file.
# Always exits 0 so a formatting hiccup never blocks the edit.

payload=$(cat)

file=$(printf '%s' "$payload" | /usr/bin/python3 -c \
  'import sys, json; d = json.load(sys.stdin); print(d.get("tool_input", {}).get("file_path", ""))' \
  2>/dev/null)

case "$file" in
  *.swift)
    if [ -f "$file" ]; then
      xcrun swift-format --in-place "$file" 2>/dev/null || true
    fi
    ;;
esac

exit 0
