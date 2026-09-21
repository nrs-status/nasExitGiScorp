# nix-expr-subst: evaluate a nix attribute set (given as a file path or as an
# expression string) and print it back, fully evaluated and formatted.
#
# Pipeline (see eval-nix-attrs.nu):
#   nix eval (full evaluation, raw nix repr)
#   -> nix-instantiate --parse - (rejects non-serializable values, e.g. lambdas)
#   -> nixfmt (pretty-print)
#   -> 2-space indentation converted to tabs
{ pkgs, ... }:
pkgs.writeShellApplication {
  name = "nix-expr-subst";
  runtimeInputs = with pkgs; [
    nushell
    nix
    nixfmt
  ];
  text = ''
    nu ${./eval-nix-attrs.nu} "$@"
  '';
}
