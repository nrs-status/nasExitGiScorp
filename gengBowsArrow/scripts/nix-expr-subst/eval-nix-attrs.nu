#!/usr/bin/env nu
# eval-nix-attrs.nu (formatter edition)
# Takes either a path to a nix file containing an attribute set,
# or the attribute set itself passed as a string.
# Returns the same attribute set (raw string on stdout, or written
# to a file with --out <path>) with all its fields fully evaluated.
#
# Pipeline:
#   1. nix eval (no --json): fully evaluates the value and prints its
#      nix-language repr.
#   2. nix-instantiate --parse -: strictly parses that repr WITHOUT
#      evaluating. Non-serializable values (functions/lambdas) print
#      as `<LAMBDA>`/`<CODE>`, which is invalid nix syntax, so parsing
#      fails -> we raise a proper error.
#   3. nixfmt: formats the repr into the final pretty form (always
#      expands attrsets/lists).
#   4. Leading 2-space indentation groups are converted to tabs to
#      match the expected output format.

def main [
  input: string,            # path to a .nix file, or the attribute set as a string
  --out: string             # optional: also write the result to this file
] {
  let is_file = (if ($input | str ends-with ".nix") or ($input | str starts-with "/")
    { ($input | path exists) } else { false })

  # 1. Fully evaluate; nix prints the raw nix-language repr of the value.
  let repr = (if $is_file {
    ^nix eval --file $input --impure
  } else {
    ^nix eval --expr $input --impure
  })

  # 2. Reject non-serializable values by parsing the repr without evaluating.
  let check = ($repr | ^nix-instantiate --parse - | complete)
  if $check.exit_code != 0 {
    error make {
      msg: $"input is not serializable \(contains functions or other non-printable values\): ($check.stderr | str trim)"
    }
  }

  # 3. Pass through the formatter (always expands attrsets/lists).
  let formatted = ($repr | ^nixfmt -)

  # 4. Convert nixfmt's 2-space indentation to tabs.
  let result = ($formatted
    | lines
    | each {|line|
      let p = ($line | parse -r '^(?<indent> *)(?<rest>.*)$' | first)
      ((($p.indent | str replace --all '  ' "\t")) + $p.rest)
    }
    | str join "\n")

  if $out != null {
    ($result + "\n") | save --force $out
    print ("written to " + $out)
  }

  print $result
}
