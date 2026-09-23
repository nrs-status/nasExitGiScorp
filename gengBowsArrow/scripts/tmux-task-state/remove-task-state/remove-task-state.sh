#!/usr/bin/env bash
set -euo pipefail

# remove-task-state [tmux-session]
#
# Unsets the `@task-status' and `@task-description' session options on
# the given (or current) tmux session, so that it no longer appears in
# `list-tasked-sessions'.

if [ "$#" -gt 1 ]; then
	echo "usage: remove-task-state [tmux-session]" >&2
	exit 1
fi

session=${1:-$(tmux display-message -p '#S')}

tmux set-option -u -t "$session" @task-status
tmux set-option -u -t "$session" @task-description
