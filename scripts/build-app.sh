#!/bin/bash
# Builds AetherOS.app (+ zip and dmg) into ./dist.noindex (Spotlight ignores folders ending in .noindex). No admin rights needed.
#
#   scripts/build-app.sh                       ad-hoc signed (works on your Mac)
#   SIGN_ID="Developer ID Application: Name (TEAMID)" scripts/build-app.sh
#   ... plus NOTARY_PROFILE=aether-notary      also notarizes and staples
#   VERSION=1.2.0 scripts/build-app.sh         set the version
#   INSTALL=1 scripts/build-app.sh             also copy into ~/Applications (no admin needed)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.0.0}"
BUILD="${BUILD:-$(date +%Y%m%d%H%M)}"
SIGN_ID="${SIGN_ID:--}"                      # "-" = ad-hoc
BUNDLE_ID="${BUNDLE_ID:-com.example.aetheros}"   # change to your own reverse-domain id
APP="dist.noindex/AetherOS.app"

rm -rf dist.noindex
echo "▸ Compiling (release, Apple Silicon + Intel)"
mkdir -p dist.noindex/slices
# Both triples share one output folder, so copy each binary out before the next build.
for ARCH in arm64 x86_64; do
  swift build -c release --triple "${ARCH}-apple-macosx14.0"
  cp "$(swift build -c release --triple "${ARCH}-apple-macosx14.0" --show-bin-path)/AetherOS" "dist.noindex/slices/AetherOS-${ARCH}"
done
BIN="dist.noindex/AetherOS-universal"
lipo -create dist.noindex/slices/AetherOS-arm64 dist.noindex/slices/AetherOS-x86_64 -output "$BIN"
lipo -info "$BIN"

echo "▸ Assembling bundle"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$BIN" "$APP/Contents/MacOS/AetherOS"
rm -rf dist.noindex/slices

echo "▸ Rendering icon"
ICONSET="dist.noindex/AppIcon.iconset"; mkdir -p "$ICONSET"
swift scripts/make-icon.swift dist.noindex/icon-1024.png
for s in 16 32 128 256 512; do
  sips -z $s $s dist.noindex/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) dist.noindex/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET" dist.noindex/icon-1024.png

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>AetherOS</string>
    <key>CFBundleDisplayName</key><string>AetherOS</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>AetherOS</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>AetherOS listens when you press the microphone button so you can speak instead of type. Audio is transcribed on this Mac.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>AetherOS transcribes your voice on-device to fill the search box.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>AetherOS reads your Finder selection to offer file conversions.</string>
</dict>
</plist>
PLIST

sign_app() {
  local target="$1"
  if [ "$SIGN_ID" = "-" ]; then
    # Ad-hoc signatures normally pin the exact binary hash, so macOS forgets Accessibility /
    # Microphone approvals after every rebuild. Pinning the bundle id instead keeps them.
    codesign --force --options runtime --timestamp=none \
      -r="designated => identifier \"$BUNDLE_ID\"" \
      --entitlements scripts/Entitlements.plist --sign - "$target"
  else
    codesign --force --options runtime --timestamp \
      --entitlements scripts/Entitlements.plist --sign "$SIGN_ID" "$target"
  fi
  codesign --verify --strict --verbose=1 "$target"
}

echo "▸ Signing ($([ "$SIGN_ID" = "-" ] && echo ad-hoc || echo "$SIGN_ID"))"
sign_app "$APP"

echo "▸ Packaging"
ditto -c -k --keepParent "$APP" "dist.noindex/AetherOS-${VERSION}.zip"
mkdir -p dist.noindex/dmg && cp -R "$APP" dist.noindex/dmg/ && ln -s /Applications dist.noindex/dmg/Applications
hdiutil create -quiet -volname "AetherOS" -srcfolder dist.noindex/dmg -ov -format UDZO "dist.noindex/AetherOS-${VERSION}.dmg"
rm -rf dist.noindex/dmg
[ "$SIGN_ID" != "-" ] && codesign --force --timestamp --sign "$SIGN_ID" "dist.noindex/AetherOS-${VERSION}.dmg"

echo "▸ Intel-only and Apple-Silicon-only packages"
for ARCH in x86_64 arm64; do
  LABEL=$([ "$ARCH" = "x86_64" ] && echo Intel || echo AppleSilicon)
  THIN="dist.noindex/$LABEL/AetherOS.app"
  mkdir -p "dist.noindex/$LABEL" && cp -R "$APP" "$THIN"
  lipo "$THIN/Contents/MacOS/AetherOS" -thin "$ARCH" -output "$THIN/Contents/MacOS/AetherOS.thin"
  mv "$THIN/Contents/MacOS/AetherOS.thin" "$THIN/Contents/MacOS/AetherOS"
  sign_app "$THIN"
  ditto -c -k --keepParent "$THIN" "dist.noindex/AetherOS-${VERSION}-${LABEL}.zip"
  rm -rf "dist.noindex/$LABEL"
done

if [ "$SIGN_ID" != "-" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "▸ Notarizing (takes a few minutes)"
  xcrun notarytool submit "dist.noindex/AetherOS-${VERSION}.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "dist.noindex/AetherOS-${VERSION}.dmg"
fi

if [ "${INSTALL:-0}" = "1" ]; then
  mkdir -p "$HOME/Applications"
  pkill -x AetherOS 2>/dev/null || true
  rm -rf "$HOME/Applications/AetherOS.app"
  cp -R "$APP" "$HOME/Applications/AetherOS.app"
  echo "▸ Installed to ~/Applications/AetherOS.app"
fi

echo "✓ Done:"; ls -1 dist.noindex
