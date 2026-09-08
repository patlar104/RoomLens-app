#!/bin/sh
# Refuse shell commands that overwrite tracked source files from an ad-hoc
# backup, and refuse destructive git history rewrites.
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
#
# Hosts and events (payload shapes differ; see _common.sh):
#   Claude Code  PreToolUse (Bash)      -> tool_input.command
#   Cursor       beforeShellExecution   -> command (top level)
#   Codex        PreToolUse (Bash)      -> tool_input.command
#   jcode        pre_tool               -> command (top level)
#
# Only shell tools carry a command, so a missing command means "allow".

. "$(dirname -- "$0")/_common.sh"

payload=$(cat)
command=$(printf '%s' "$payload" | hook_field command)

[ -n "$command" ] || exit 0

# Emit a denial in the form each host understands, then exit 2. Exit code 2 is
# honoured as "block" by Claude Code, Cursor, and Codex alike; the JSON body is
# what Cursor renders natively, and stderr is what the others surface.
deny() {
	printf '{"permission":"deny","user_message":%s,"agent_message":%s}\n' \
		"$(printf '%s' "$1" | /usr/bin/python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')" \
		"$(printf '%s' "$1" | /usr/bin/python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')"
	printf '%s\n' "$1" >&2
	exit 2
}

# --- restoring a tracked file from an ad-hoc backup -------------------------
# Matches: cp /tmp/x.bak <path>.swift, cp ~/x.backup <path>.swift, etc.
# Deliberately narrow: only flags copies FROM a backup-looking source INTO a
# source file, so ordinary `cp` usage is unaffected.
# shellcheck disable=SC2016  # $TMPDIR is matched literally, not expanded.
if printf '%s' "$command" \
	| grep -Eq '(^|[;&|] *)(cp|mv|rsync)[^;&|]*(/tmp/|/var/folders/|\$TMPDIR|~/)[^;&|]*\.(bak|backup|orig|save|copy|[0-9]+)[^;&|]*\.(swift|m|mm|h|plist|pbxproj)'
then
	deny 'BLOCKED: restoring a tracked source file from an ad-hoc backup.

Another agent may be editing this file in the same working directory. A copy
from /tmp can silently revert their in-flight edits, leaving an empty
`git diff` and no error. This has already happened once in this repo.

Use git, which is the authoritative source and is concurrency-safe:

    git checkout -- <file>        # discard working-tree changes
    git restore --source=HEAD <file>
    git stash                     # park your own work first

If you are running a mutation test, prefer:

    git stash && <mutate> && <test> && git checkout -- <file> && git stash pop'
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
	# shellcheck disable=SC2016  # Backticks are prose, not command substitution.
	deny 'BLOCKED: destructive git command in a possibly shared working directory.

`reset --hard`, `clean -f`, and `push --force` can discard commits or files
another agent is working on. If you genuinely need this, run it yourself, or
use a safer form (`git restore <path>`, `git push --force-with-lease`).'
fi

exit 0
