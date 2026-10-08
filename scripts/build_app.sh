#!/bin/bash
# Builds build/Screenshooter.app (universal: Apple Silicon + Intel).
#   VERSION=1.0.0 ./scripts/build_app.sh
#   ARCHS="arm64" ./scripts/build_app.sh          faster, for this Mac only
#   SIGN_IDENTITY=- ./scripts/build_app.sh        ad-hoc signature
#   OUT_DIR=build/release ./scripts/build_app.sh  another place for the bundle (make_dmg.sh uses it)
#
# By default the app is signed with the first "Developer ID Application" or "Apple Development" identity
# in the keychain: macOS ties the screen recording and accessibility permissions to the signature, and
# an ad-hoc one changes with every build, so the permissions would have to be granted again each time.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Screenshooter"
BUNDLE_ID="${BUNDLE_ID:-com.screenshooter.app}"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
ARCHS="${ARCHS:-arm64 x86_64}"
if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -E '"(Developer ID Application|Apple Development):' | head -1 | sed -E 's/.*"(.*)".*/\1/')"
    SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi
APP="${OUT_DIR:-$ROOT/build}/$APP_NAME.app"

# 1. Icon
[ -f Resources/AppIcon.icns ] || swift scripts/make_icon.swift

# 2. Compile
echo "==> swift build ($ARCHS)"
ARCH_FLAGS=()
for arch in $ARCHS; do ARCH_FLAGS+=(--arch "$arch"); done
swift build -c release "${ARCH_FLAGS[@]}" --product "$APP_NAME" 2>&1 | grep -E "error|warning: unre|Build complete" || true
BIN="$(swift build -c release "${ARCH_FLAGS[@]}" --product "$APP_NAME" --show-bin-path)/$APP_NAME"
[ -x "$BIN" ] || { echo "build failed"; exit 1; }

# 3. Bundle
echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/ru.lproj" "$APP/Contents/Resources/en.lproj"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
strip -x "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null || true
# SwiftPM writes the deployment target into the SDK field of the binary. macOS reads that field to decide
# whether the app gets the current design (Liquid Glass on macOS 26 and later), so write the real SDK.
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
MIN_OS="$(vtool -show-build "$APP/Contents/MacOS/$APP_NAME" | awk '/minos/ { print $2; exit }')"
vtool -set-build-version macos "$MIN_OS" "$SDK_VERSION" -replace \
      -output "$APP/Contents/MacOS/$APP_NAME.sdk" "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null
mv "$APP/Contents/MacOS/$APP_NAME.sdk" "$APP/Contents/MacOS/$APP_NAME"
chmod +x "$APP/Contents/MacOS/$APP_NAME"
echo "    macOS $MIN_OS+, SDK $SDK_VERSION"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Interface languages: Russian strings are the keys in the code, English comes from Localizable.strings
# (generated from scripts/l10n/en.json; it fails when a text has no translation).
if [ "${SKIP_L10N:-0}" != 1 ]; then
    python3 scripts/l10n/make_strings.py >/dev/null
    cp Resources/en.lproj/Localizable.strings "$APP/Contents/Resources/en.lproj/"
fi
COPYRIGHT_EN="Screenshooter — smart screenshots with a shelf in the notch."
COPYRIGHT_RU="Screenshooter — умные скриншоты с полкой у выреза экрана."
cat > "$APP/Contents/Resources/en.lproj/InfoPlist.strings" <<STRINGS
CFBundleDisplayName = "$APP_NAME";
CFBundleName = "$APP_NAME";
NSHumanReadableCopyright = "$COPYRIGHT_EN";
STRINGS
cat > "$APP/Contents/Resources/ru.lproj/InfoPlist.strings" <<STRINGS
CFBundleDisplayName = "$APP_NAME";
CFBundleName = "$APP_NAME";
NSHumanReadableCopyright = "$COPYRIGHT_RU";
STRINGS

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>ru</string></array>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <key>NSHumanReadableCopyright</key><string>$COPYRIGHT_EN</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>$BUNDLE_ID</string>
            <key>CFBundleURLSchemes</key><array><string>screenshooter</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST
printf "APPL????" > "$APP/Contents/PkgInfo"

# 4. Sign
echo "==> codesign ($SIGN_IDENTITY)"
xattr -cr "$APP"
if [ "$SIGN_IDENTITY" = "-" ]; then
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
else
    # A secure timestamp is needed for notarization (Developer ID); local development builds skip it.
    TIMESTAMP="--timestamp=none"
    [[ "$SIGN_IDENTITY" == Developer\ ID* ]] && TIMESTAMP="--timestamp"
    codesign --force --options runtime "$TIMESTAMP" --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "==> done: $APP ($(du -sh "$APP" | cut -f1))"
lipo -info "$APP/Contents/MacOS/$APP_NAME"
