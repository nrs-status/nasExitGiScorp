#!/usr/bin/env bash
set -euo pipefail

# task-underway <task-description> [tmux-session]
#
# Sets the `@task-status' and `@task-description' session options on the
# given (or current) tmux session, marking it as having a task underway.
# The task state can be listed with `list-tasked-sessions' and cleared
# with `remove-task-state'.

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
	echo "usage: task-underway <task-description> [tmux-session]" >&2
	exit 1
fi

description=$1
session=${2:-$(tmux display-message -p '#S')}

tmux set-option -t "$session" @task-status "underway"
tmux set-option -t "$session" @task-description "$description"
