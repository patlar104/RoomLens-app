#!/bin/sh
# Stop hook: when any Swift file is uncommitted in the working tree, verify the
# app still builds before the turn ends. Runs asynchronously; on failure it
# re-wakes Claude with the compiler errors (exit 2). Exits 0 quietly when no
# Swift file changed or the build succeeds, so trivial turns pay nothing.

cd "$CLAUDE_PROJECT_DIR" 2>/dev/null || exit 0

# Staged, unstaged, or untracked .swift changes?
if ! git status --porcelain 2>/dev/null | grep -q '\.swift"\?$'; then
  exit 0
fi

log=$(mktemp)
if set -o pipefail 2>/dev/null; xcodebuild build \
    -project RoomLens.xcodeproj \
    -scheme RoomLens \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
    >"$log" 2>&1; then
  rm -f "$log"
  exit 0
fi

echo "Build is broken after Swift changes — fix before finishing. xcodebuild output:"
grep -E 'error:|BUILD FAILED|Undefined symbol|linker command failed' "$log" | head -40
rm -f "$log"
exit 2
