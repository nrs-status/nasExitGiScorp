#!/usr/bin/env bash
set -euo pipefail

# list-tasked-sessions
#
# Lists every tmux session that has a task state set (i.e. that has been
# touched by `task-underway' or `task-done' and not cleared by
# `remove-task-state'), one line per session:
#
#   <session>: <status> - <description>

if [ "$#" -ne 0 ]; then
	echo "usage: list-tasked-sessions" >&2
	exit 1
fi

if ! tmux list-sessions >/dev/null 2>&1; then
	# No tmux server running: no sessions, hence no tasked sessions.
	exit 0
fi

tmux list-sessions -F "#{session_name}	#{@task-status}	#{@task-description}" |
	awk -F '\t' '$2 != "" { printf "%s: %s - %s\n", $1, $2, $3 }'
