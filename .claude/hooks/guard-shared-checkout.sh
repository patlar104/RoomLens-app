#!/bin/sh
# PreToolUse(Bash) hook: refuse shell commands that overwrite tracked source
# files from an ad-hoc backup, and refuse destructive git history rewrites.
#
# WHY THIS EXISTS
# ---------------
# Multiple agents can share one working directory. A mutation test ("break the
# code, prove the suite fails, restore it") writes a backup to /tmp and later
# restores it. When two sessions do this concurrently, a stale restore lands on
# top of another session's in-progress edits and silently reverts them, leaving
# an empty `git diff` and no error anywhere.
#
# That is exactly what happened once: `cp /tmp/cs.bak <tracked>.swift` from one
# session clobbered a fix being written by another, two seconds after it was
# applied.
#
# Restoring a file is legitimate; doing it from an unversioned /tmp copy is
# not, because git already holds the authoritative version. This hook blocks
# the unsafe form and names the safe one.

payload=$(cat)

command=$(printf '%s' "$payload" | /usr/bin/python3 -c \
  'import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print("")
    sys.exit(0)
print(d.get("tool_input", {}).get("command", ""))' 2>/dev/null)

[ -n "$command" ] || exit 0

# --- restoring a tracked file from an ad-hoc backup -------------------------
# Matches: cp /tmp/x.bak <path>.swift, cp ~/x.backup <path>.swift, etc.
# Deliberately narrow: only flags copies FROM a backup-looking source INTO a
# source file, so ordinary `cp` usage is unaffected.
# shellcheck disable=SC2016  # $TMPDIR is matched literally, not expanded.
if printf '%s' "$command" \
  | grep -Eq '(^|[;&|] *)(cp|mv|rsync)[^;&|]*(/tmp/|/var/folders/|\$TMPDIR|~/)[^;&|]*\.(bak|backup|orig|save|copy|[0-9]+)[^;&|]*\.(swift|m|mm|h|plist|pbxproj)'
then
  cat >&2 <<'MSG'
BLOCKED: restoring a tracked source file from an ad-hoc backup.

Another agent may be editing this file in the same working directory. A copy
from /tmp can silently revert their in-flight edits, leaving an empty
`git diff` and no error. This has already happened once in this repo.

Use git, which is the authoritative source and is concurrency-safe:

    git checkout -- <file>        # discard working-tree changes
    git restore --source=HEAD <file>
    git stash                     # park your own work first

If you are running a mutation test, prefer:

    git stash && <mutate> && <test> && git checkout -- <file> && git stash pop
MSG
  exit 2
fi

# --- destructive history rewrites -------------------------------------------
# A shared checkout makes these especially dangerous: they can discard commits
# another session just made.
# NOTE: POSIX grep -E has no negative lookahead, so `--force-with-lease`
# is excluded by testing for it separately rather than inline.
is_force_push=0
if printf '%s' "$command" | grep -Eq 'git +push +.*--force'; then
  is_force_push=1
  printf '%s' "$command" | grep -q -- '--force-with-lease' && is_force_push=0
fi

if [ "$is_force_push" -eq 1 ] \
  || printf '%s' "$command" | grep -Eq 'git +reset +--hard' \
  || printf '%s' "$command" | grep -Eq 'git +clean +-[A-Za-z]*f'
then
  cat >&2 <<'MSG'
BLOCKED: destructive git command in a possibly shared working directory.

`reset --hard`, `clean -f`, and `push --force` can discard commits or files
another agent is working on. If you genuinely need this, run it yourself, or
use a safer form (`git restore <path>`, `git push --force-with-lease`).
MSG
  exit 2
fi

exit 0
