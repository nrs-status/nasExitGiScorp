# BUILDING-APPS — a step-by-step guide for agents

This document is for an **automated agent** (or a human) that has the
`iphone-dev-service` package and wants to create, sign and install a native
iPhone application on a USB-connected device — no macOS, no Xcode, no root.

It ends with the worked example of **GarageCam**, a camera app that uploads its
photos to a Garage object store, which was built and verified with this exact
package.

---

## 0. What the package gives you

`iphone-dev-service up` starts everything needed for the *signing and delivery*
half of iOS development:

| Component | What it does |
|---|---|
| `usbmuxd` | talks to the device over USB (private socket, persistent pairing) |
| anisette server (podman) | Apple ADI/anisette machine (persisted ⇒ no repeat 2FA) |
| `anisette-proxy` / `gsa-proxy` | work around Apple's 503/429 edge behaviour and the static signer's TLS limits |
| AltServer + patched `zsign` | Apple-ID login, App-ID registration, provisioning profile, signature, USB install |
| unwrapped `clang` (`clang-ios`) + `ld64.lld` + `ldid` | cross-compile Mach-O arm64 and sign |
| `build-ios.sh`, `sideload.py` | the `build-install` / `sideload` commands |

`build-ios.sh` is a small, readable reference build: rewrite it if you need a
different layout, but for single-binary Objective-C apps it is usually enough.

---

## 1. Prerequisites checklist

- [ ] `iphone-dev-service up` succeeds and `status` shows all components
      running with a valid pairing.
- [ ] An **`iPhoneOS.sdk`** is available. The package cannot ship it (Apple
      licence). Default location:
      `$IPHONE_DEV_CONFIG/ios-sdk/iPhoneOS.sdk` (usually
      `~/.config/iphone-dev-service/ios-sdk/iPhoneOS.sdk`). Override with
      `IOS_SDK=…`.
      A convenient public source is the Theos SDK collection:
      ```bash
      git clone --depth 1 --filter=blob:none --sparse https://github.com/theos/sdks.git /tmp/theos-sdks
      cd /tmp/theos-sdks && git sparse-checkout set iPhoneOS16.5.sdk
      mv iPhoneOS16.5.sdk "$IPHONE_DEV_CONFIG/ios-sdk/iPhoneOS.sdk"
      ```
- [ ] Credentials in `$IPHONE_DEV_CONFIG/credentials` (or
      `$IPHONE_DEV_CREDENTIALS`, or `./credentials.txt`):
      ```
      APPLE_ID=you@example.com
      APPLE_PASSWORD=…
      ```
- [ ] On the device: **Developer Mode ON** and, at install time, the phone
      **unlocked** (iOS refuses `installation_proxy` on a locked device).
- [ ] One-time Apple 2FA per anisette machine (the package persists the
      machine, so this is rare).

Verify all of the above with:

```bash
iphone-dev-service doctor
```

---

## 2. The app directory

`build-ios.sh` expects a directory containing:

```
MyApp/
  Info.plist        # bundle metadata (see below)
  main.m            # one or more .m / .mm / .c files
  …resources…       # anything else is copied into MyApp.app
```

### `Info.plist` — the keys that matter

```xml
<key>CFBundleIdentifier</key> <string>@BUNDLE_ID@</string>   <!-- substituted at build -->
<key>CFBundleExecutable</key> <string>@APP_NAME@</string>    <!-- substituted at build -->
<key>CFBundleName</key>       <string>@APP_NAME@</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>MinimumOSVersion</key>   <string>15.0</string>
<key>UIDeviceFamily</key>     <array><integer>1</integer></array>
<key>UILaunchScreen</key>     <dict/>

<!-- REQUIRED for camera apps; iOS kills the process without it -->
<key>NSCameraUsageDescription</key>
<string>This app uses the camera.</string>

<!-- REQUIRED for plain-HTTP/local-network endpoints (e.g. Garage on the LAN) -->
<key>NSAppTransportSecurity</key>
<dict>
  <key>NSAllowsArbitraryLoads</key><true/>
  <key>NSAllowsLocalNetworking</key><true/>
</dict>
<key>NSLocalNetworkUsageDescription</key>
<string>Talks to a local object store.</string>
<key>NSBonjourServices</key>
<array><string>_http._tcp</string><string>_s3._tcp</string></array>
```

`@APP_NAME@` / `@BUNDLE_ID@` are substituted by `build-ios.sh`; AltServer then
prefixes the team id, so the final bundle id on the device looks like
`com.example.myapp.KH63MN6Y7J`.

### A minimal app

A complete, compiling camera template is installed with the package:

```bash
cp -r "$IPHONE_DEV_SERVICE_SHARE/examples/camera" ./myapp
```

(If `IPHONE_DEV_SERVICE_SHARE` is unset, it is
`…/share/iphone-dev-service` inside the package store path.)

---

## 3. Build + sign + install

One command does everything — compile against the SDK, package `Payload/*.app`
into an `.ipa`, then let AltServer register the App ID, fetch a provisioning
profile, sign with `zsign`, and install over USB:

```bash
FRAMEWORKS="Foundation UIKit AVFoundation" \
APP_NAME=MyApp BUNDLE_ID=com.example.myapp \
iphone-dev-service build-install ./myapp
```

Useful environment variables:

| Variable | Meaning |
|---|---|
| `IOS_SDK` | path to `iPhoneOS.sdk` |
| `APP_NAME` | executable / bundle name (defaults to the dir name) |
| `BUNDLE_ID` | `CFBundleIdentifier` before AltServer adds the team prefix |
| `MIN_IOS` | deployment target (default `15.0`) |
| `FRAMEWORKS` | space-separated frameworks to link (default `Foundation UIKit`) |
| `IPHONE_DEV_UDID` | force a device when several are attached |
| `IPHONE_DEV_2FA_FILE` | where to read a 2FA code (default `./2fa.txt`) |

To build an already-signed `.ipa` you produced elsewhere, use the raw command:

```bash
iphone-dev-service sideload ./MyApp.ipa
```

If Apple asks for 2FA, the driver notifies the desktop and waits for the code
in `./2fa.txt` (or the file named by `IPHONE_DEV_2FA_FILE`). Once the anisette
machine has completed 2FA, later runs are non-interactive.

---

## 4. First launch on the device (unavoidable, once per app)

The install is fully automated, but two things are inherently user actions:

1. **Open the app** on the home screen.
2. **Answer the prompts**: Camera access, and — for any app that talks to a
   LAN address — the **Local Network** prompt.

> The Local Network prompt is triggered by the *first* connection attempt. A
> launch-time "self-test" upload will therefore time out until the user taps
> **Allow**; the next attempt succeeds. Keep this in mind when writing retry
> logic or diagnostics.

Installation itself does not require the phone to be unlocked, but the
`installation_proxy` step does. If `sideload` fails with
`Could not connect to device` / `Password protected`, ask the user to unlock
the phone and retry.

---

## 5. Debugging

- The driver writes the whole AltServer log to
  `$IPHONE_DEV_STATE/run/sideload.log`.
- Device-side `NSLog` output can be streamed with
  `nix develop -c idevicesyslog` (or `pymobiledevice3 syslog`) if you have it.
- Verify what is installed:
  ```bash
  USBMUXD_SOCKET_ADDRESS="UNIX:$IPHONE_DEV_STATE/run/usbmuxd.sock" \
    ideviceinstaller -u "$UDID" list
  ```
- Check the stack any time with `iphone-dev-service status` and
  `iphone-dev-service doctor`.

---

## 6. Worked example — GarageCam (camera → Garage object store)

This is the app that was actually built and verified with the package: it
captures a photo and `PUT`s the JPEG straight to a Garage S3 bucket using AWS
Signature Version 4.

### 6.1 The S3 endpoint

Garage exposes an S3 API. Two things to get right:

- **Reachability.** The host firewall only forwards a fixed set of TCP ports.
  Run the store on a **firewall-open** port, or add the port to the host
  firewall config. (In the test the user-level Garage was put on `8201`, which
  the running firewall already accepted.)
- **Credentials.** The system Garage's admin token can be root-only, so an
  equivalent user-level Garage instance with a known key is often the pragmatic
  choice:
  ```bash
  garage -c ~/garage-iphone/garage.toml bucket create iphone-image-intake
  garage -c ~/garage-iphone/garage.toml key create iphone-intake-key   # prints Key ID + Secret
  garage -c ~/garage-iphone/garage.toml bucket allow iphone-image-intake \
      --read --write --owner --key iphone-intake-key
  ```

### 6.2 SigV4 in Objective-C (reusable)

`CommonCrypto` is part of `libSystem`, so no extra framework is needed:

```objc
#import <CommonCrypto/CommonDigest.h>
#import <CommonCrypto/CommonHMAC.h>

static NSString *HexEncode(const unsigned char *b, size_t n) {
    NSMutableString *s = [NSMutableString stringWithCapacity:n*2];
    for (size_t i=0;i<n;i++) [s appendFormat:@"%02x", b[i]];
    return s;
}
static NSData *SHA256(NSData *d){unsigned char o[32];CC_SHA256(d.bytes,(CC_LONG)d.length,o);
    return [NSData dataWithBytes:o length:32];}
static NSData *HMAC(NSData *k, NSData *d){unsigned char o[32];
    CCHmac(kCCHmacAlgSHA256,k.bytes,k.length,d.bytes,d.length,o);
    return [NSData dataWithBytes:o length:32];}
static NSData *HMACStr(NSData *k, NSString *s){
    return HMAC(k,[s dataUsingEncoding:NSUTF8StringEncoding]);}

static NSDictionary *SigV4(NSString *method, NSString *host, NSString *uri,
                           NSData *body, NSString *ak, NSString *sk) {
    NSDateFormatter *df=[NSDateFormatter new]; df.dateFormat=@"yyyyMMdd";
    df.timeZone=[NSTimeZone timeZoneWithName:@"UTC"];
    NSDateFormatter *af=[NSDateFormatter new]; af.dateFormat=@"yyyyMMdd'T'HHmmss'Z'";
    af.timeZone=[NSTimeZone timeZoneWithName:@"UTC"];
    NSString *ds=[df stringFromDate:[NSDate date]], *ad=[af stringFromDate:[NSDate date]];
    NSString *ph=HexEncode(SHA256(body).bytes,32);
    NSString *ch=[NSString stringWithFormat:@"host:%@\nx-amz-content-sha256:%@\nx-amz-date:%@\n",host,ph,ad];
    NSString *sh=@"host;x-amz-content-sha256;x-amz-date";
    NSString *cr=[NSString stringWithFormat:@"%@\n%@\n\n%@\n%@\n%@",method,uri,ch,sh,ph];
    NSString *scope=[NSString stringWithFormat:@"%@/garage/s3/aws4_request",ds];
    NSString *sts=[NSString stringWithFormat:@"AWS4-HMAC-SHA256\n%@\n%@\n%@",
                   ad,scope,HexEncode(SHA256([cr dataUsingEncoding:NSUTF8StringEncoding]).bytes,32)];
    NSString *aws4 = [@"AWS4" stringByAppendingString:sk];
    NSData *k = HMACStr([aws4 dataUsingEncoding:NSUTF8StringEncoding], ds);
    k=HMACStr(k,@"garage"); k=HMACStr(k,@"s3"); k=HMACStr(k,@"aws4_request");
    NSString *sig=HexEncode(HMACStr(k,sts).bytes,32);
    return @{@"Authorization":[NSString stringWithFormat:
                @"AWS4-HMAC-SHA256 Credential=%@/%@, SignedHeaders=%@, Signature=%@",ak,scope,sh,sig],
             @"x-amz-date":ad, @"x-amz-content-sha256":ph};
}
```

### 6.3 The upload

```objc
NSString *key = [NSString stringWithFormat:@"photos/%@-%06x.jpg", stamp, arc4random_uniform(0xFFFFFF)];
NSString *uri = [NSString stringWithFormat:@"/%@/%@", @"iphone-image-intake", key];
NSString *host = @"wranhearst.local:8201";              // or the raw LAN IP
NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://%@%@", host, uri]];
NSDictionary *h = SigV4(@"PUT", host, uri, jpeg, ACCESS_KEY, SECRET_KEY);

NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
req.HTTPMethod = @"PUT"; req.HTTPBody = jpeg; req.timeoutInterval = 15;
[req setValue:h[@"Authorization"]        forHTTPHeaderField:@"Authorization"];
[req setValue:h[@"x-amz-date"]           forHTTPHeaderField:@"x-amz-date"];
[req setValue:h[@"x-amz-content-sha256"] forHTTPHeaderField:@"x-amz-content-sha256"];
[req setValue:@"image/jpeg"              forHTTPHeaderField:@"Content-Type"];
[[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
    /* 2xx ⇒ done; on network error, retry the next endpoint (see below) */
}] resume];
```

Because the iOS Local Network permission may still be pending on the first
attempt, the uploader tries a list of endpoints and falls back on *network*
errors:

```objc
+ (NSArray<NSString *> *)endpoints {
    return @[ @"wranhearst.local:8201", @"192.168.2.12:8201" ];
}
```

### 6.4 Build + install it

```bash
cp -r "$IPHONE_DEV_SERVICE_SHARE/examples/camera" apps/garagecam   # then add the SigV4 uploader
FRAMEWORKS="Foundation UIKit AVFoundation CoreGraphics" \
APP_NAME=GarageCam BUNDLE_ID=com.example.garagecam \
iphone-dev-service build-install apps/garagecam
```

### 6.5 Verify the upload from the host

```bash
KID=…; SEC=…                                  # from `garage key create`
curl -s --aws-sigv4 "aws:amz:garage:s3" --user "$KID:$SEC" \
  "http://127.0.0.1:8201/iphone-image-intake?list-type=2&prefix=photos/"
```

### 6.6 Result

`build-install` reported `Notify: Installation Succeeded`, the device listed
`com.example.garagecam.KH63MN6Y7J 1.0 "GarageCam"`, and a real capture landed
in Garage:

```
photos/20260916T023446-99eb8b.jpg   3,073,105 bytes   JPEG 4032x3024
Exif: manufacturer=Apple, model=iPhone 15 Pro, software=26.6.1
```

---

## 7. Hard-won gotchas

1. **`clang-unwrapped` has no builtin headers on its search path.**
   `stdarg.h`, `stdbool.h`, `arm_neon.h`, … live in clang's separate `lib`
   output. The package installs a `clang-ios` wrapper with
   `-resource-dir <clang.lib>/lib/clang/18`; `build-ios.sh` uses it. If you
   write your own build system, point `-resource-dir` (or `-isystem`) there.
2. **Do not use `-fmodules`** for this cross-build; it drags in the SDK module
   map and compiler headers and fails. Plain `-fobjc-arc` works.
3. **ATS blocks plain HTTP** unless `NSAllowsArbitraryLoads` (or
   `NSAllowsLocalNetworking`) is set. Garage on the LAN is HTTP.
4. **`NSCameraUsageDescription` is mandatory**; without it iOS terminates the
   app the moment it touches the camera.
5. **The Local Network prompt** only fires on the first LAN connection and the
   request that triggers it usually times out. Expect the first self-test to
   fail and the retry (or the next capture) to succeed.
6. **Install needs the phone unlocked**; pairing/auth/signing do not.
7. **Free Apple ID limits**: 3 apps at a time, ~7-day provisioning profiles.
   Re-run `sideload`/`build-install` to refresh.
8. **AltServer prefixes the team id** to the bundle id, so the on-device id is
   `com.example.yourapp.<TEAMID>`.

---

## 8. Quickstart (copy-paste)

```bash
# 1. environment
iphone-dev-service up && iphone-dev-service doctor

# 2. SDK (once)
[ -d "$IPHONE_DEV_CONFIG/ios-sdk/iPhoneOS.sdk" ] || {
  git clone --depth 1 --filter=blob:none --sparse https://github.com/theos/sdks.git /tmp/theos-sdks
  (cd /tmp/theos-sdks && git sparse-checkout set iPhoneOS16.5.sdk)
  mkdir -p "$IPHONE_DEV_CONFIG/ios-sdk"
  mv /tmp/theos-sdks/iPhoneOS16.5.sdk "$IPHONE_DEV_CONFIG/ios-sdk/iPhoneOS.sdk"
}

# 3. app from the template
cp -r "$IPHONE_DEV_SERVICE_SHARE/examples/camera" ./myapp
$EDITOR ./myapp/main.m ./myapp/Info.plist

# 4. build + sign + install
FRAMEWORKS="Foundation UIKit AVFoundation" APP_NAME=MyApp BUNDLE_ID=com.example.myapp \
  iphone-dev-service build-install ./myapp

# 5. on the device: open MyApp, answer Camera + Local Network prompts
# 6. re-run as needed: iphone-dev-service sideload <ipa>
```