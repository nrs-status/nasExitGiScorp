# iphone-dev-service

A Nix package that provides a **signing and delivery environment for iOS apps
over USB**: it lets an agent (or a human) sign and install arbitrary `.ipa`
files onto a USB-connected iPhone without root and without macOS, and — with a
user-supplied iPhoneOS SDK — compile simple apps and install them too.

It is *not* an AltStore installer. AltStore was merely the payload used to
develop and validate the pipeline; the pipeline itself is app-agnostic.

## What it runs

| Component | Role |
|---|---|
| `usbmuxd` (unprivileged, private socket) | USB device transport + pairing |
| `anisette-server` (podman, persisted) | Apple ADI/anisette machine |
| `anisette-proxy.py` (`:6969`) | strips the `com.apple.dt.Xcode` client-info Apple 503s |
| `gsa-proxy.py` (`:4443`) | `gsa.apple.com`, **fresh TLS connection per request** (avoids 429), refreshes anisette for 2FA |
| `gsa-proxy.py` (`:4444`) | `developerservices2.apple.com` (App IDs, provisioning profiles) |
| AltServer + patched `zsign` | Apple-ID login, App-ID registration, signing, install |
| `clang` + `ld64.lld` + `ldid` | build toolchain for `build-install` |

The static AltServer binary cannot speak TLS to Apple from this host, so its
Apple base URLs are rewritten to the local proxies and the proxies do the TLS.

## Usage

```bash
# bring the stack up (fetches the AltServer image on first run)
iphone-dev-service up
iphone-dev-service status

# sign + install any IPA (prompts the desktop for a 2FA code if Apple asks)
iphone-dev-service sideload ./MyApp.ipa
#   ...when notified, write the code to ./2fa.txt

# compile a source directory and install it (needs IOS_SDK, see below)
iphone-dev-service build-install ./MyApp

# stop everything (the anisette machine identity is kept)
iphone-dev-service down
```

Credentials are read from `$IPHONE_DEV_CREDENTIALS`, else
`$IPHONE_DEV_CONFIG/credentials`, else `./credentials.txt`:

```
APPLE_ID=you@example.com
APPLE_PASSWORD=yourpassword
```

`iphone-dev-service env` prints the exports needed to drive
`AltServer.patched` by hand; `iphone-dev-service doctor` diagnoses the stack.

## Building your own apps

> **Agents: read [BUILDING-APPS.md](BUILDING-APPS.md)** — a complete
> step-by-step guide to creating, signing and installing a native app with this
> package, including the worked **GarageCam** (camera → Garage S3) example and
> the SigV4 uploader code. A compiling camera template is installed in
> `examples/camera/`.

`build-install <dir>` expects a directory with an `Info.plist`, one or more
`.m`/`.mm`/`.c` files, and any resources. It calls `build-ios.sh`, which runs
`clang -target arm64-apple-ios<ver> -isysroot $IOS_SDK … -fuse-ld=lld` and
packages a `Payload/App.app` `.ipa`.

**The one thing this package cannot provide is Apple's `iPhoneOS.sdk`** — it is
copyrighted and must be supplied by the user. Copy it out of Xcode on a Mac
(`/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk`)
or install a Theos SDK, then either export `IOS_SDK` or place it at:

```
$IPHONE_DEV_CONFIG/ios-sdk/iPhoneOS.sdk
```

Camera apps need `NSCameraUsageDescription` in `Info.plist`. No special
entitlement is required for camera access; iOS asks the user at runtime.

## Staying unattended

* The anisette machine state lives in `$IPHONE_DEV_STATE/anisette`, mounted into
  the container with `:U`, so the same Apple-trusted machine is reused across
  restarts. After the **first** 2FA approval, later logins do not ask again.
* The pairing record lives in `$IPHONE_DEV_STATE/lockdown`. Seed it from
  `$IPHONE_DEV_CONFIG/lockdown` (copied from a previously paired host) to avoid
  the Trust prompt.
* `seed-anisette <container>` migrates an already-trusted anisette machine out
  of an existing container.
* `install-user-service` writes a `systemd --user` unit that starts the stack
  at login.

Remaining human touch-points:

* enabling **Developer Mode** once per device (Settings → Privacy & Security →
  Developer Mode → reboot);
* the first **2FA** approval per anisette machine (afterwards Apple trusts the
  machine and logins are non-interactive);
* **unlocking the iPhone for the install step**. Pairing, authentication and
  signing all work while the phone is locked, but iOS refuses
  `com.apple.mobile.installation_proxy` on a locked device
  (`Could not connect to device` / `Password protected`). Keep the device
  unlocked (screen on) while `sideload`/`build-install` runs;
* the first camera/privacy prompt inside each app.

## Layout

```
default.nix              the package
iphone-dev-service.sh    the CLI
anisette-proxy.py        anisette client-info rewriter
gsa-proxy.py             connection-per-request Apple HTTPS proxy
sideload.py              AltServer driver (2FA prompt handling)
patch_altserver.py       rewrites AltServer's Apple base URLs
build-ios.sh             clang cross-build + IPA packaging
Dockerfile.anisette      anisette-server image + libplist fix
README.md                this file
BUILDING-APPS.md         agent guide: build/sign/install native apps
examples/camera/         minimal camera app template (Info.plist + main.m)
```