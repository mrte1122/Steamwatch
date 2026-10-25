#!/bin/bash
# Publishes a signed release: ./scripts/release.sh 1.2.0 ["Release notes"]
# Bumps VERSION, builds the universal app, signs the zip, tags, pushes, and creates the
# GitHub release with Steamwatch.zip and Steamwatch.zip.sig. Without notes, GitHub generates them.
#
# Environment: STEAMWATCH_SIGN_IDENTITY / STEAMWATCH_NOTARY_PROFILE (see build-app.sh; the notary profile
# defaults to quotacat-notary, which works because profiles are per Apple ID) and STEAMWATCH_SIGNING_KEY
# (the Ed25519 private key, default ~/.config/steamwatch/update-signing-key).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
NOTES="${2:-}"
die() { echo "error: $*" >&2; exit 1; }

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "usage: scripts/release.sh X.Y.Z [notes]"
[[ "$(git branch --show-current)" == "main" ]] || die "release from main"
[[ -z "$(git status --porcelain)" ]] || die "commit or stash your changes first"
git rev-parse "v$VERSION" >/dev/null 2>&1 && die "tag v$VERSION already exists"

# The app only accepts updates signed by the key whose public half is compiled in.
PUB="$(swift scripts/sign-update.swift public)"
grep -q "$PUB" Sources/Steamwatch/Updater.swift || die "signing key doesn't match Updater.publicKey"

echo "$VERSION" > VERSION
git add VERSION
git diff --cached --quiet || git commit -q -m "Release v$VERSION"

# Notarize whenever a Developer ID certificate is available; otherwise ship ad-hoc signed.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
    ./scripts/build-app.sh --notarize
else
    echo "warning: no Developer ID certificate; this release won't be notarized" >&2
    ./scripts/build-app.sh --zip
fi
build/Steamwatch.app/Contents/MacOS/Steamwatch --selftest >/dev/null || die "self-tests failed"
swift scripts/sign-update.swift sign build/Steamwatch.zip > build/Steamwatch.zip.sig

git tag "v$VERSION"
git push -q origin main "v$VERSION"

if [[ -n "$NOTES" ]]; then
    gh release create "v$VERSION" build/Steamwatch.zip build/Steamwatch.zip.sig --title "Steamwatch $VERSION" --notes "$NOTES"
else
    gh release create "v$VERSION" build/Steamwatch.zip build/Steamwatch.zip.sig --title "Steamwatch $VERSION" --generate-notes
fi

# Point the Homebrew cask (github.com/mrte1122/homebrew-tap, Casks/steamwatch.rb) at the new release.
# Non-fatal: the release itself is already published. Skipped while the cask doesn't exist yet.
SHA="$(shasum -a 256 build/Steamwatch.zip | awk '{print $1}')"
TAP="$(mktemp -d)"
if ! gh repo clone mrte1122/homebrew-tap "$TAP" -- -q 2>/dev/null; then
    echo "warning: couldn't clone mrte1122/homebrew-tap; Homebrew cask not updated" >&2
elif [[ ! -f "$TAP/Casks/steamwatch.rb" ]]; then
    echo "note: no Casks/steamwatch.rb in mrte1122/homebrew-tap yet; skipping the cask bump (sha256 $SHA)"
elif sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$TAP/Casks/steamwatch.rb" \
     && git -C "$TAP" -c user.name="Tyler Lovelady" -c user.email="24609723+mrte1122@users.noreply.github.com" \
          commit -qam "Update Steamwatch to $VERSION" \
     && git -C "$TAP" push -q; then
    echo "Homebrew cask updated to $VERSION"
else
    echo "warning: couldn't update the Homebrew cask; edit Casks/steamwatch.rb in mrte1122/homebrew-tap by hand" >&2
fi
rm -rf "$TAP"

echo "Released v$VERSION"
