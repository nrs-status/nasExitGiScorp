{ pkgs, ... }:
# pi-json-span-processor: Haskell stream processor aggregating the JSON-lines
# event stream emitted by `pi --mode json' into span events (agent, turn,
# message, tool_execution); see ./SPEC.md for the behavioural specification.
# Internalized from the former `process-pi-stream' project; built with the
# repository's nixpkgs.
pkgs.haskellPackages.callCabal2nix "pi-json-span-processor" ./. { }
