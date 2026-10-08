#!/bin/bash
# Publishes a GitHub release: builds dist/Screenshooter-<version>.dmg from the committed code, tags v<version>,
# pushes main and the tag, then publishes the release with the DMG attached.
#   VERSION=1.1.0 NOTES=~/notes-1.1.0.md ./scripts/release.sh     (keep the notes file outside the repo)
# git goes through the remote's deploy key (git@github-screenshooter:..., see ~/.ssh/config). The release API needs a
# fine-grained token of tihomirov-nick with Contents: Read and write on this repo, kept in the Keychain
# (account tihomirov-nick, service TOKEN_SERVICE, by default github-screenshooter-token).
# gh's own login is a different account and is not used. Without such a token the script stops before the build.
# Safe to re-run: an existing tag on HEAD and an existing (draft) release are reused.
set -euo pipefail

VERSION="${VERSION:?set VERSION, e.g. VERSION=1.1.0}"
NOTES="${NOTES:?set NOTES to a Markdown file with the release notes}"
[ -f "$NOTES" ] || { echo "no notes file: $NOTES"; exit 1; }
NOTES="$(cd "$(dirname "$NOTES")" && pwd)/$(basename "$NOTES")"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
REPO="tihomirov-nick/screenshooter"
SERVICE="${TOKEN_SERVICE:-github-screenshooter-token}"
TAG="v$VERSION"
DMG="dist/Screenshooter-$VERSION.dmg"

# 1. The release must match committed code on main
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || { echo "switch to main first"; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "commit or stash changes first (untracked files count too)"; exit 1; }
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && [ "$(git rev-parse "$TAG^{commit}")" != "$(git rev-parse HEAD)" ]; then
    echo "$TAG already points to another commit"; exit 1
fi

# 2. Token, checked by creating the draft release before anything is built or pushed
TOKEN="$(security find-generic-password -a tihomirov-nick -s "$SERVICE" -w 2>/dev/null)" || TOKEN=""
[ -n "$TOKEN" ] || { echo "no GitHub token in the Keychain (account tihomirov-nick, service $SERVICE)"; exit 1; }
gh_() { GH_TOKEN="$TOKEN" gh "$@"; }
if ! gh_ release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    gh_ release create "$TAG" --repo "$REPO" --draft --title "Screenshooter $VERSION" --notes-file "$NOTES" >/dev/null || {
        echo "the token from Keychain service $SERVICE can't create releases in $REPO"
        echo "(it needs Contents: Read and write on this repo; nothing was built or pushed)"
        exit 1
    }
fi

# 3. Build (build_app.sh regenerates Localizable.strings, which is tracked; make_dmg.sh signs with "tihomirov-nick")
VERSION="$VERSION" ./scripts/make_dmg.sh
[ -z "$(git status --porcelain)" ] || { echo "the build changed tracked files, commit them and run again:"; git status --short; exit 1; }

# The app in the DMG must be signed by the certificate "tihomirov-nick": installed copies update only to such a version.
CERT_SHA1="af82036140843a7d76497ea8e4cd23403c8aedc2"
MOUNT="$(mktemp -d /tmp/screenshooter-release.XXXXXX)"
hdiutil attach "$DMG" -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" >/dev/null
REQUIREMENT="$(codesign -d -r- "$MOUNT/Screenshooter.app" 2>&1 | tr '[:upper:]' '[:lower:]' || true)"
hdiutil detach "$MOUNT" -quiet || hdiutil detach "$MOUNT" -force -quiet
rmdir "$MOUNT" 2>/dev/null || true
case "$REQUIREMENT" in
    *"certificate leaf = h\"$CERT_SHA1\""*) echo "==> the app in the DMG is signed by tihomirov-nick" ;;
    *) echo "the app in $DMG is not signed by the certificate tihomirov-nick: installed copies would refuse it; nothing pushed"; exit 1 ;;
esac

# 4. Tag and push
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || git tag -a "$TAG" -m "Screenshooter $VERSION"
git push origin main "$TAG"

# 5. Attach the DMG and publish
gh_ release upload "$TAG" "$DMG" --repo "$REPO" --clobber
gh_ release edit "$TAG" --repo "$REPO" --draft=false --title "Screenshooter $VERSION" --notes-file "$NOTES"
echo "==> https://github.com/$REPO/releases/tag/$TAG"
