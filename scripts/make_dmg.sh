#!/bin/bash
# Builds the app and packs it into dist/Screenshooter-<version>.dmg
#   VERSION=1.0.0 ./scripts/make_dmg.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${VERSION:-1.0.0}"
export VERSION
# Release builds are signed ad-hoc unless SIGN_IDENTITY says otherwise: a development certificate carries the
# developer's e-mail. They go to build/release, so the local build/Screenshooter.app keeps its own signature
# (and with it the permissions macOS gave it).
export SIGN_IDENTITY="${SIGN_IDENTITY:--}"
export OUT_DIR="$ROOT/build/release"

./scripts/build_app.sh

STAGE="$ROOT/build/dmg"
DMG="$ROOT/dist/Screenshooter-$VERSION.dmg"
rm -rf "$STAGE"
mkdir -p "$STAGE" "$ROOT/dist"
cp -R "$OUT_DIR/Screenshooter.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/docs/Как установить.txt" "$ROOT/docs/How to install.txt" "$STAGE/"

rm -f "$DMG"
echo "==> creating $DMG"
hdiutil create -volname "Screenshooter $VERSION" -srcfolder "$STAGE" -fs HFS+ -format ULFO -ov "$DMG" >/dev/null
if [ "${SIGN_IDENTITY:--}" != "-" ]; then
    codesign --force --sign "$SIGN_IDENTITY" "$DMG"
fi
hdiutil verify "$DMG" >/dev/null && echo "==> verified"
echo "==> $DMG ($(du -h "$DMG" | cut -f1))"
