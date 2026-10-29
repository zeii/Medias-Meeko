#!/bin/bash
# Builds the native "Médias Meeko.app" (universal, no dependency) and a zip to share it.
set -euo pipefail

NAME="Médias Meeko"
EXE="MediasMeeko"
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/$NAME.app"
RES="$APP/Contents/Resources"
BUILD="$(mktemp -d)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$RES"
cp "$DIR/ui.html" "$DIR/assets/meeko-icon.png" "$RES/"

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -parse-as-library -target "$arch-apple-macos12.0" \
    "$DIR/macos/MediasMeeko.swift" -o "$BUILD/$EXE-$arch"
done
lipo -create "$BUILD/$EXE-arm64" "$BUILD/$EXE-x86_64" -output "$APP/Contents/MacOS/$EXE"

ICONSET="$BUILD/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$DIR/assets/meeko-icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$DIR/assets/meeko-icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>local.meeko.medias</string>
  <key>CFBundleExecutable</key><string>$EXE</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>CFBundleVersion</key><string>2.0</string>
  <key>CFBundleDevelopmentRegion</key><string>fr</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature: required for arm64 code; it does not replace Apple notarization.
codesign --force --deep --sign - "$APP"

# Nudge Finder/Dock into dropping a cached icon.
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" 2>/dev/null || true

# Keep the copy in /Applications (Launchpad, Spotlight) in sync.
INSTALLED="/Applications/$NAME.app"
rm -rf "$INSTALLED"
ditto "$APP" "$INSTALLED"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALLED" 2>/dev/null || true

# Shareable zip: the app + install notes.
DIST="$DIR/dist"
STAGE="$BUILD/Medias-Meeko"
mkdir -p "$DIST" "$STAGE"
cp -R "$APP" "$STAGE/"
cp "$DIR/LISEZMOI.txt" "$STAGE/"
rm -f "$DIST/Medias-Meeko.zip"
ditto -c -k --norsrc --noextattr --noqtn --keepParent "$STAGE" "$DIST/Medias-Meeko.zip"
rm -rf "$BUILD"

echo "Créé : $APP"
echo "Installé : $INSTALLED"
echo "À partager : $DIST/Medias-Meeko.zip"
