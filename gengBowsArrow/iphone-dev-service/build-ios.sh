#!/usr/bin/env bash
# build-ios.sh — compile a simple iOS app on Linux and package it as an .ipa.
#
# The one thing this environment cannot conjure is Apple's iPhoneOS SDK: it is
# copyrighted and must be supplied by the user (copy it out of Xcode, or use a
# Theos SDK). Point IOS_SDK at it.
#
# Usage:
#   build-ios.sh SOURCE_DIR [OUTPUT_IPA]
#
# SOURCE_DIR must contain:
#   - Info.plist                  (may use @APP_NAME@ / @BUNDLE_ID@ placeholders)
#   - one or more .m / .mm / .c source files
#   - any resources to copy into the .app
#
# Environment:
#   IOS_SDK      path to iPhoneOS.sdk                (required)
#   APP_NAME     bundle name / executable name       (default: dir basename)
#   BUNDLE_ID    CFBundleIdentifier                  (default: com.example.$APP_NAME)
#   MIN_IOS      deployment target                   (default: 15.0)
#   FRAMEWORKS   space-separated frameworks to link  (default: "Foundation UIKit")
#   ACSDK        optional path to an extra SDK (unused by default)
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: build-ios.sh SOURCE_DIR [OUTPUT_IPA]" >&2
  exit 1
fi

SRC="$(cd "$1" && pwd)"
APP_NAME="${APP_NAME:-$(basename "$SRC")}"
APP_NAME="${APP_NAME//[^A-Za-z0-9_]/}"
BUNDLE_ID="${BUNDLE_ID:-com.example.$APP_NAME}"
MIN_IOS="${MIN_IOS:-15.0}"
FRAMEWORKS="${FRAMEWORKS:-Foundation UIKit}"
OUT_IPA="${2:-$(pwd)/$APP_NAME.ipa}"

if [ -z "${IOS_SDK:-}" ] || [ ! -d "${IOS_SDK:-/nonexistent}" ]; then
  echo "build-ios.sh: IOS_SDK is not set or not a directory." >&2
  echo "  Provide an iPhoneOS.sdk (from Xcode or a Theos SDK) and export IOS_SDK." >&2
  exit 2
fi

CLANG="${IOS_CLANG:-clang}"
if ! command -v "$CLANG" >/dev/null 2>&1; then
  echo "build-ios.sh: compiler '$CLANG' not found (set IOS_CLANG, or use the iphone-dev-service dev shell)." >&2
  exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
APP_DIR="$WORK/Payload/$APP_NAME.app"
mkdir -p "$APP_DIR"

# Info.plist with placeholders resolved
if [ -f "$SRC/Info.plist" ]; then
  sed -e "s/@APP_NAME@/$APP_NAME/g" -e "s/@BUNDLE_ID@/$BUNDLE_ID/g" \
      "$SRC/Info.plist" > "$APP_DIR/Info.plist"
else
  echo "build-ios.sh: $SRC/Info.plist not found" >&2
  exit 2
fi

# Compile sources
sources=()
while IFS= read -r -d '' f; do sources+=("$f"); done < <(
  find "$SRC" -maxdepth 2 \( -name '*.m' -o -name '*.mm' -o -name '*.c' \) -print0
)
if [ ${#sources[@]} -eq 0 ]; then
  echo "build-ios.sh: no .m/.mm/.c sources under $SRC" >&2
  exit 2
fi

framework_flags=()
for fw in $FRAMEWORKS; do
  framework_flags+=("-framework" "$fw")
done

echo "build-ios.sh: compiling ${#sources[@]} source(s) for arm64-apple-ios$MIN_IOS" >&2
"$CLANG" \
  -target "arm64-apple-ios$MIN_IOS" \
  -isysroot "$IOS_SDK" \
  -fobjc-arc -O2 \
  "${framework_flags[@]}" \
  -fuse-ld=lld \
  -Wl,-platform_version,ios,"$MIN_IOS","$MIN_IOS" \
  -Wl,-dead_strip \
  "${sources[@]}" \
  -o "$APP_DIR/$APP_NAME"

# Copy resources (everything except Info.plist and sources)
while IFS= read -r -d '' f; do
  rel="${f#"$SRC"/}"
  mkdir -p "$APP_DIR/$(dirname "$rel")"
  cp "$f" "$APP_DIR/$rel"
done < <(
  find "$SRC" -maxdepth 2 -type f \
    ! -name 'Info.plist' ! -name '*.m' ! -name '*.mm' ! -name '*.c' \
    ! -name '*.sh' ! -name '*.md' ! -name '*.ipa' -print0
)

# Package
rm -f "$OUT_IPA"
( cd "$WORK" && zip -qry "$OUT_IPA" Payload )
echo "$OUT_IPA"
echo "build-ios.sh: wrote $OUT_IPA" >&2