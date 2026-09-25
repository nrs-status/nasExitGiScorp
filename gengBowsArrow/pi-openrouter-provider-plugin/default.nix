{ pkgs, ... }:
# pi-openrouter-provider-plugin: a pi extension that surfaces the upstream
# provider OpenRouter routes requests to, and lets the user pin/prefer one.
# See ./SPEC.md.
#
# The output consists of nothing else than the pi extension itself (no wrapper,
# no package.json): load it directly with `pi -e <out>/share/pi/extensions/openrouter-provider.ts`.
pkgs.runCommand "pi-openrouter-provider-plugin" { } ''
	mkdir -p $out/share/pi/extensions
	cp ${./openrouter-provider.ts} $out/share/pi/extensions/openrouter-provider.ts
''