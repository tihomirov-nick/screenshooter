#!/bin/bash
# Builds the app and packs it into dist/Screenshooter-<version>.dmg
#   VERSION=1.0.0 ./scripts/make_dmg.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${VERSION:-1.3.0}"
export VERSION
# Release builds are signed with the app's own self-signed certificate "tihomirov-nick" (no e-mail in it, unlike a
# development certificate): installed copies update themselves only to a version signed by the same certificate.
# Without it the build is signed ad-hoc and the copies installed from this DMG will never update. Release builds go to
# build/release, so the local build/Screenshooter.app keeps its own signature (and the permissions macOS gave it).
if [ -z "${SIGN_IDENTITY:-}" ]; then
    if security find-identity -p codesigning 2>/dev/null | grep -q '"tihomirov-nick"'; then
        SIGN_IDENTITY="tihomirov-nick"
    else
        SIGN_IDENTITY="-"
        echo "!!! The certificate \"tihomirov-nick\" is not in the keychain: signing ad-hoc." >&2
        echo "!!! Copies installed from this DMG cannot update themselves, and the next releases will not install over them." >&2
    fi
fi
export SIGN_IDENTITY
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
