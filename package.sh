#!/bin/bash
# Builds a release zip of EasyDL.app for both Apple silicon and Intel.
#
# build.sh makes an app for whichever Mac you are on, which is what you want while
# developing. This makes the thing you attach to a GitHub release: one universal
# binary, ad-hoc signed, zipped with ditto so the bundle survives the round trip.
#
#   ./package.sh            -> dist/EasyDL-<version>.zip and its SHA-256
#   CODESIGN_IDENTITY="Developer ID Application: ..." ./package.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$ROOT/dist/EasyDL.app"
CONTENTS="$APP/Contents"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT/Resources/Info.plist")"
ZIP="$ROOT/dist/EasyDL-$VERSION.zip"

echo "==> Building universal (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64 --package-path "$ROOT"
BIN="$(swift build -c release --arch arm64 --arch x86_64 --package-path "$ROOT" --show-bin-path)/EasyDL"

echo "==> Self-test"
"$BIN" --self-test

echo "==> Assembling bundle"
rm -rf "$APP" "$ZIP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN" "$CONTENTS/MacOS/EasyDL"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"
cp "$ROOT/EasyDLArt/EasyDL.icns" "$CONTENTS/Resources/AppIcon.icns"

echo "==> Signing"
codesign --force --deep --sign "${CODESIGN_IDENTITY:--}" "$APP"

echo "==> Checking what we are about to ship"
ARCHS="$(lipo -archs "$CONTENTS/MacOS/EasyDL")"
MINOS="$(otool -l "$CONTENTS/MacOS/EasyDL" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
echo "    architectures : $ARCHS"
echo "    minimum macOS : $MINOS"
case "$ARCHS" in
  *arm64*) ;;
  *) echo "    ERROR: no arm64 slice"; exit 1 ;;
esac
case "$ARCHS" in
  *x86_64*) ;;
  *) echo "    ERROR: no x86_64 slice — Intel Macs could not run this"; exit 1 ;;
esac
codesign --verify --strict "$APP" && echo "    signature     : valid"

echo "==> Zipping"
# ditto, not zip: it preserves the bundle's structure and extended attributes, which
# a plain zip does not.
( cd "$ROOT/dist" && ditto -c -k --keepParent "EasyDL.app" "$(basename "$ZIP")" )

echo ""
echo "Built $ZIP"
echo "SHA-256: $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
echo "Size:    $(du -h "$ZIP" | cut -f1)"
