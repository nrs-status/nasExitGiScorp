#!/usr/bin/env nushell
# create-pi-session <GIT BRANCH NAME> [<MODEL NAME>]
#
# Creates a new git worktree (via `wt switch --create`) based on the current
# branch, lets you write instructions.txt for it with `vipe`, then opens a
# tmux session (via `sesh connect`) containing two windows:
#   1. `pi "Read and execute ./instructions.txt" --model <MODEL>`
#   2. a plain shell at the new worktree
#
# The model may be given as the optional second argument; if omitted, it is
# read from the DEFAULT_PI_MODEL environment variable.

def main [branch: string, model?: string] {
    # --- 0. Resolve the model: second argument, else DEFAULT_PI_MODEL env var -
    let model = (if $model == null {
        let env_model = ($env.DEFAULT_PI_MODEL? | default "" | str trim)
        if ($env_model | is-empty) {
            print $"(ansi red)Error:(ansi reset) no model given. Pass a model argument or set the DEFAULT_PI_MODEL environment variable."
            exit 1
        }
        $env_model
    } else {
        $model
    })
    # --- 1. Validate that the first argument is a valid Git branch name -------
    let check = (do { git check-ref-format --branch $branch } | complete)
    if $check.exit_code != 0 {
        print $"(ansi red)Error:(ansi reset) '($branch)' is not a valid Git branch name."
        print $check.stderr
        exit 1
    }

    # --- 2. Determine the current branch --------------------------------------
    let current = (git branch --show-current | str trim)
    if ($current | is-empty) {
        print $"(ansi red)Error:(ansi reset) not on any branch (detached HEAD?), cannot create a worktree from it."
        exit 1
    }

    # --- 3. Create the worktree -----------------------------------------------
    print $"Creating worktree for branch (ansi cyan)($branch)(ansi reset) based on (ansi cyan)($current)(ansi reset)..."
    let wt = (do { ^wt switch --create $branch --base $current } | complete)
    if $wt.exit_code != 0 {
        print $"(ansi red)Error:(ansi reset) 'wt switch --create ($branch) --base ($current)' failed:"
        print $wt.stderr
        exit 1
    }
    print $wt.stdout

    # Resolve the path of the worktree just created for $branch
    let wt_path = (git worktree list --porcelain
        | lines
        | split list ""
        | each {|block|
            {
                path: ($block | where {|l| $l =~ '^worktree '} | first | str replace -r '^worktree ' ''),
                branch: ($block | where {|l| $l =~ '^branch '} | first | str replace -r '^branch ' '')
            }
        }
        | where {|e| $e.branch == $"refs/heads/($branch)"}
        | get 0.path)
    print $"Worktree path: (ansi cyan)($wt_path)(ansi reset)"

    # --- 4. Write instructions.txt via vipe ------------------------------------
    print $"Opening editor to write (ansi cyan)($wt_path)/instructions.txt(ansi reset) - save and quit to continue..."
    ^vipe | save -f $"($wt_path)/instructions.txt"

    # --- 5. Prepare the tmux session and its two windows -----------------------
    # sesh names sessions after the directory basename with dots replaced by
    # underscores; pre-create the session (detached) with its two windows so
    # they exist when `sesh connect` attaches.
    let session = ($wt_path | path basename | str replace -a "." "_")
    let has = (do { tmux has-session -t $session } | complete)
    if $has.exit_code != 0 {
        let pi_cmd = $"pi \"Read and execute ./instructions.txt\" --model '($model)'"
        # Window 1: pi, primed with the instructions prompt and the given model
        ^tmux new-session -d -s $session -c $wt_path -n pi $pi_cmd
        # Window 2: a plain shell at the worktree
        ^tmux new-window -d -t $session -n shell -c $wt_path
    }

    # --- 6. Connect to the session with sesh -----------------------------------
    print $"Connecting to tmux session (ansi cyan)($session)(ansi reset)..."
    ^sesh connect $wt_path
}
