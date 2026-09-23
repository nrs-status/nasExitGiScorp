#!/usr/bin/env bash
set -euo pipefail

# task-done [tmux-session]
#
# Sets the `@task-status' session option to `done' on the given (or
# current) tmux session, marking its task as complete.  The task state
# can be listed with `list-tasked-sessions' and cleared with
# `remove-task-state'.

if [ "$#" -gt 1 ]; then
	echo "usage: task-done [tmux-session]" >&2
	exit 1
fi

session=${1:-$(tmux display-message -p '#S')}

tmux set-option -t "$session" @task-status "done"
