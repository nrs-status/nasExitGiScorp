#!/usr/bin/env bash
set -euo pipefail

# taskmux: unified task-state management for tmux sessions.
#
# A task state is stored in the `@task-status' / `@task-description'
# session options of a tmux session.  `taskmux' replaces the previous
# four separate scripts:
#
#   taskmux start <task-description> [tmux-session]
#       (was: task-underway) marks a session as having a task underway.
#   taskmux done [tmux-session]
#       (was: task-done) marks a session's task as complete.
#   taskmux list
#       (was: list-tasked-sessions) lists tasked sessions, one line per
#       session: <session>: <status> - <description>.
#   taskmux clear [tmux-session]
#       (was: remove-task-state) unsets a session's task state.

usage() {
	echo "usage: taskmux start <task-description> [tmux-session]" >&2
	echo "       taskmux done [tmux-session]" >&2
	echo "       taskmux list" >&2
	echo "       taskmux clear [tmux-session]" >&2
	exit 1
}

current_session() {
	tmux display-message -p '#S'
}

cmd_start() {
	if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
		usage
	fi
	description=$1
	session=${2:-$(current_session)}

	tmux set-option -t "$session" @task-status "underway"
	tmux set-option -t "$session" @task-description "$description"
}

cmd_done() {
	if [ "$#" -gt 1 ]; then
		usage
	fi
	session=${1:-$(current_session)}

	tmux set-option -t "$session" @task-status "done"
}

cmd_list() {
	if [ "$#" -ne 0 ]; then
		usage
	fi

	if ! tmux list-sessions >/dev/null 2>&1; then
		# No tmux server running: no sessions, hence no tasked sessions.
		exit 0
	fi

	tmux list-sessions -F "#{session_name}	#{@task-status}	#{@task-description}" |
		awk -F '\t' '$2 != "" { printf "%s: %s - %s\n", $1, $2, $3 }'
}

cmd_clear() {
	if [ "$#" -gt 1 ]; then
		usage
	fi
	session=${1:-$(current_session)}

	tmux set-option -u -t "$session" @task-status
	tmux set-option -u -t "$session" @task-description
}

if [ "$#" -lt 1 ]; then
	usage
fi

command=$1
shift

case "$command" in
	start) cmd_start "$@" ;;
	done) cmd_done "$@" ;;
	list) cmd_list "$@" ;;
	clear) cmd_clear "$@" ;;
	*)
		echo "taskmux: unknown subcommand: $command" >&2
		usage
		;;
esac