#!/usr/bin/env bash
set -euo pipefail

# taskmux: unified task-state management for tmux sessions.
#
# A task state is stored in the `@task-status' / `@task-description'
# session options of a tmux session.  `taskmux' replaces the previous
# four separate scripts:
#
#   taskmux start [task-description] [tmux-session]
#       (was: task-underway) marks a session as having a task underway.
#       Without a task description the current git branch's name is
#       used; outside a git repository `start' with no argument is an
#       error: it prints a message and exits with status 1 without
#       marking anything.
#   taskmux done [tmux-session]
#       (was: task-done) marks a session's task as complete.
#   taskmux list
#       (was: list-tasked-sessions) lists tasked sessions, one line per
#       session: <session>: <status> - <description>.  On a terminal
#       the listing becomes a selectable menu: j/k moves the cursor,
#       Return switches to the selected session, q/Escape quits.
#   taskmux clear [tmux-session]
#       (was: remove-task-state) unsets a session's task state.

usage() {
	echo "usage: taskmux start [task-description] [tmux-session]" >&2
	echo "       taskmux done [tmux-session]" >&2
	echo "       taskmux list" >&2
	echo "       taskmux clear [tmux-session]" >&2
	exit 1
}

current_session() {
	tmux display-message -p '#S'
}

cmd_start() {
	if [ "$#" -gt 2 ]; then
		usage
	fi
	if [ "$#" -ge 1 ]; then
		description=$1
	else
		# No description given: fall back to the current git branch's
		# name.  Outside a git repository (or on a detached HEAD, where
		# there is no branch name), fail with an error instead of
		# marking any session.
		if ! description=$(git symbolic-ref --short HEAD 2>/dev/null); then
			echo "taskmux start: not in a git repository (or no current branch); a task description is required" >&2
			exit 1
		fi
	fi
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

	# Each row is "<name>\t<name>: <status> - <description>".  The bare
	# name is kept alongside the display line because it is needed for
	# `tmux switch-client'; session names cannot contain ':' but
	# descriptions may, so the display line alone is not enough to
	# recover the name.
	local row
	local -a names=() entries=()
	while IFS= read -r row; do
		names+=("${row%%$'\t'*}")
		entries+=("${row#*$'\t'}")
	done < <(
		tmux list-sessions -F "#{session_name}	#{@task-status}	#{@task-description}" |
			awk -F '\t' '$2 != "" { printf "%s\t%s: %s - %s\n", $1, $1, $2, $3 }'
	)

	if [ "${#names[@]}" -eq 0 ]; then
		return 0
	fi

	# Non-interactive fallback: plain listing, as before.
	if [ ! -t 0 ] || [ ! -t 2 ]; then
		printf '%s\n' "${entries[@]}"
		return 0
	fi

	# Interactive selection: j/k (or the arrow keys) move the cursor,
	# Return switches the current tmux client to the selected session,
	# q/Escape/Ctrl-C quits without switching.
	local count=${#names[@]} sel=0 key='' rest='' chosen=''
	local old_stty
	old_stty=$(stty -g </dev/tty)
	trap 'stty "$old_stty" </dev/tty' EXIT
	# Not `raw': that disables output post-processing (ONLCR), which
	# would make every successive menu line start at the column where
	# the previous one ended.  Disabling the canonical input mode and
	# the echo is enough to get one key at a time; -isig makes Ctrl-C
	# arrive as a \003 byte (handled below) instead of a signal.
	stty -echo -icanon -isig </dev/tty

	list_draw() {
		# On the first call simply draw; on later calls move the cursor
		# back up over the previously drawn lines and clear them first.
		if [ "$1" -eq 0 ]; then
			printf '\033[%dA\033[J' "$((count + 1))"
		fi
		local i
		for ((i = 0; i < count; i++)); do
			if [ "$i" -eq "$sel" ]; then
				printf '\033[7m> %s\033[0m\n' "${entries[$i]}"
			else
				printf '  %s\n' "${entries[$i]}"
			fi
		done
		printf 'j/k: move, Return: switch, q: quit\n'
	}

	exec 3</dev/tty
	local first=1
	while :; do
		list_draw "$first"
		first=0
		# -N (not -n): a literal newline (Enter, possibly translated
		# from \r by ICRNL) must end up in "key" rather than being
		# swallowed as an (empty) line terminator.
		IFS= read -rsN1 -u 3 key || key=''
		case "$key" in
			j)
				sel=$(((sel + 1) % count))
				;;
			k)
				sel=$(((sel + count - 1) % count))
				;;
			$'\r' | $'\n')
				chosen=${names[$sel]}
				break
				;;
			$'\e')
				# Escape may start an arrow-key sequence: if the next
				# two bytes arrive quickly, treat [A/[B as up/down,
				# otherwise treat the Escape itself as "quit".
				rest=''
				if IFS= read -rsn2 -t 0.05 -u 3 rest && [ "$rest" = '[A' ]; then
					sel=$(((sel + count - 1) % count))
				elif [ "$rest" = '[B' ]; then
					sel=$(((sel + 1) % count))
				else
					break
				fi
				;;
			q | $'\003')
				break
				;;
		esac
	done
	exec 3>&-
	stty "$old_stty" </dev/tty
	trap - EXIT

	if [ -n "$chosen" ]; then
		if [ -n "${TMUX:-}" ]; then
			tmux switch-client -t "$chosen"
		else
			# Not running inside tmux: attach to the selected session.
			tmux attach-session -t "$chosen"
		fi
	fi
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