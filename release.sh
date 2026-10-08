#!/bin/bash
# Cuts a release: bumps the version, tags it, publishes a GitHub release
# and points the Homebrew formula at it.
#   ./release.sh 0.3.0                 notes generated from the commits
#   ./release.sh 0.3.0 notes.md        notes from a file
# Expects the tap checked out next to this repo (or TAP_DIR=…).
set -euo pipefail
cd "$(dirname "$0")"

VERSION=${1:?usage: ./release.sh X.Y.Z [notes.md]}
NOTES=${2:-}
TAP=${TAP_DIR:-../homebrew-tap}
FORMULA=$TAP/Formula/wallpaper-picker.rb

fail() { echo "$1" >&2; exit 1; }
[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Version must look like 1.2.3"
[[ $(git branch --show-current) == main ]] || fail "Release from main"
[[ -z $(git status --porcelain) ]] || fail "Commit or stash your changes first"
git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null && fail "v$VERSION already exists"
[[ -f $FORMULA ]] || fail "No formula at $FORMULA (set TAP_DIR)"
[[ -z $(git -C "$TAP" status --porcelain) ]] || fail "The tap has uncommitted changes"
[[ -z $NOTES || -f $NOTES ]] || fail "No notes file $NOTES"

echo "==> Building $VERSION"
sed -i '' "s/^VERSION=.*/VERSION=$VERSION/" bundle.sh
./bundle.sh >/dev/null

echo "==> Tagging v$VERSION"
git commit -qam "Release $VERSION"
git tag -a "v$VERSION" -m "v$VERSION"
git push -q
git push -q origin "v$VERSION"
REVISION=$(git rev-parse "v$VERSION^{commit}")

echo "==> GitHub release"
if [[ -n $NOTES ]]; then
    gh release create "v$VERSION" --title "v$VERSION" --notes-file "$NOTES"
else
    gh release create "v$VERSION" --title "v$VERSION" --generate-notes
fi

echo "==> Homebrew formula"
git -C "$TAP" pull -q
sed -i '' -e "s/tag:      \"v[^\"]*\"/tag:      \"v$VERSION\"/" \
          -e "s/revision: \"[0-9a-f]*\"/revision: \"$REVISION\"/" "$FORMULA"
grep -q "v$VERSION" "$FORMULA" && grep -q "$REVISION" "$FORMULA" || fail "Couldn't update $FORMULA"
git -C "$TAP" commit -qam "wallpaper-picker $VERSION"
git -C "$TAP" push -q

echo "Released $VERSION. Users update with: brew update && brew upgrade wallpaper-picker"
