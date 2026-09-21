# iphone-dev-service — signing and delivery environment for iOS apps over USB.
#
# This package bundles the whole stack that lets an agent sign and install
# arbitrary .ipa files onto a USB-connected iPhone without root and without
# macOS, and (with a user-supplied iPhoneOS SDK) build them too:
#
#   * usbmuxd + libimobiledevice + ideviceinstaller  (device transport)
#   * the iOS-26-valid AltServer + patched zsign      (Apple-ID auth + signing)
#   * a locally-provisioned anisette machine          (via podman)
#   * two connection-per-request Apple HTTPS proxies  (gsa.apple.com,
#     developerservices2.apple.com) that work around Apple's 503/429 edge
#     behaviour and the static binary's TLS limitations
#   * clang + ld64.lld + ldid                         (build toolchain)
#
# The `iphone-dev-service` CLI (see ./iphone-dev-service.sh) starts/stops the
# stack and drives it (`up`, `sideload`, `build-install`, …).  The one input
# this package cannot provide is Apple's iPhoneOS.sdk, which is copyrighted and
# must be supplied by the user (see ./README.md).
{
  pkgs,
  pkgsLib,
  ...
}:

let
  version = "1.0.0";

  runtimeInputs = (with pkgs; [
    # shell + text utilities
    bashInteractive
    coreutils
    findutils
    gnused
    gnugrep
    gawk
    jq
    # network + crypto
    curl
    cacert
    openssl
    # container runtime for the anisette server
    podman
    # device transport
    usbmuxd
    libimobiledevice
    libusbmuxd
    ideviceinstaller
    # desktop notification (2FA prompt)
    libnotify
    # scripting
    python3
  ]) ++ (with pkgs; [
    # build toolchain used by `build-install`
    # NOTE: the *unwrapped* clang is required: the nix cc-wrapper injects
    # Linux-only flags (--gcc-toolchain, -dynamic-linker=...glibc...) that
    # break Mach-O linking.
    llvmPackages_18.clang-unwrapped
    llvmPackages_18.lld
    ldid
    zsign
    # packaging
    zip
  ]);

  share = "share/iphone-dev-service";

  # clang's builtin headers (stdarg.h, stdbool.h, arm_neon.h, …) live in the
  # separate `lib' output of clang-unwrapped; the bare compiler does not find
  # them on its own, so wrap it with an explicit -resource-dir.
  clang = pkgs.llvmPackages_18.clang-unwrapped;
  clangResourceDir = "${clang.lib}/lib/clang/18";
in
pkgs.stdenv.mkDerivation {
  pname = "iphone-dev-service";
  inherit version;
  src = ./.;

  nativeBuildInputs = [ pkgs.makeWrapper ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/${share} $out/bin

    # data/python assets
    install -Dm644 anisette-proxy.py gsa-proxy.py sideload.py \
      patch_altserver.py Dockerfile.anisette README.md BUILDING-APPS.md $out/${share}/
    install -Dm755 build-ios.sh $out/${share}/build-ios.sh

    # example app template for agents
    cp -r examples $out/${share}/examples

    # compiler wrapper for iOS cross-builds (adds clang's resource dir)
    cat > $out/bin/clang-ios <<EOF
#!${pkgs.runtimeShell}
exec ${clang}/bin/clang -resource-dir ${clangResourceDir} "\$@"
EOF
    chmod +x $out/bin/clang-ios

    # CLI (with the share dir + version substituted in)
    substitute iphone-dev-service.sh $out/bin/iphone-dev-service \
      --subst-var-by shareDir "$out/${share}" \
      --subst-var-by version "${version}"
    chmod +x $out/bin/iphone-dev-service

    wrapProgram $out/bin/iphone-dev-service \
      --prefix PATH : ${pkgsLib.makeBinPath runtimeInputs} \
      --set IPHONE_DEV_SERVICE_SHARE "$out/${share}" \
      --set IOS_CLANG "$out/bin/clang-ios"

    runHook postInstall
  '';

  meta = with pkgsLib; {
    description = "Signing and delivery environment for sideloading iOS apps over USB (usbmuxd + anisette + AltServer/zsign + Apple proxies)";
    longDescription = ''
      Starts an unprivileged usbmuxd on a private socket, a locally-provisioned
      Apple anisette machine (in podman), and two plain-HTTP -> HTTPS proxies
      that work around Apple's 503/429 edge behaviour and the static AltServer
      binary's TLS limitations.  Provides `iphone-dev-service sideload` to sign
      and install any .ipa with the user's Apple ID, and `build-install` to
      compile a simple Objective-C app against a user-supplied iPhoneOS.sdk and
      install it.
    '';
    mainProgram = "iphone-dev-service";
    platforms = platforms.linux;
    license = licenses.mit;
  };
}