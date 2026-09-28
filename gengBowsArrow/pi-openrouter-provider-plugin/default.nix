{
  pkgs,
  ...
}:
# pi-openrouter-provider-plugin: a pi extension that surfaces the upstream
# provider OpenRouter routes requests to, and lets the user pin/prefer one.
# See ./SPEC.md.
#
# The output is a pi extension package (see SPEC.md section 0): the entry
# file, its package manifest, and the runtime dependencies declared in
# ./package.json (installed offline from the ./package-lock.json lockfile),
# laid out so that pi's documented extension dependency resolution finds
# node_modules next to the entry file:
#   $out/share/pi/extensions/pi-openrouter-provider-plugin/
# Load it with `pi -e <out>/share/pi/extensions/pi-openrouter-provider-plugin/openrouter-provider.ts`.
pkgs.buildNpmPackage {
  pname = "pi-openrouter-provider-plugin";
  version = "0.1.0";
  src = ./.;
  npmDepsHash = "sha256-2Y88c0QiL/4oiIjlODJJ2uhk48zJ/BZPWOpkkXfeSYE=";
  # Nothing to build: pi transpiles the entry file (jiti) at load time.
  dontNpmBuild = true;
  installPhase = ''
    mkdir -p $out/share/pi/extensions/pi-openrouter-provider-plugin
    cp package.json package-lock.json openrouter-provider.ts config.example.toml \
      $out/share/pi/extensions/pi-openrouter-provider-plugin/
    cp -r node_modules $out/share/pi/extensions/pi-openrouter-provider-plugin/node_modules
  '';
}