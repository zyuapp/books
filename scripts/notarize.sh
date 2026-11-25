#!/bin/sh
# Notarizes and staples "build.noindex/Page Owl.app", then writes the release assets to dist/:
# PageOwl.zip and PageOwl.dmg, each with a .sha256 file, plus Books.zip: the same app named Books.app,
# for installs from before the rename, whose updater downloads Books.zip and expects Books.app inside.
#
# Needs an App Store Connect API key: APPLE_API_KEY (path to the .p8), APPLE_API_KEY_ID and
# APPLE_API_ISSUER. The app must already be signed with Developer ID (PAGE_OWL_RELEASE=1).
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

app="build.noindex/Page Owl.app"
[ -d "$app" ] || { echo "Missing $app; run scripts/build-app.sh first" >&2; exit 1; }
: "${APPLE_API_KEY:?}" "${APPLE_API_KEY_ID:?}" "${APPLE_API_ISSUER:?}"

submit() {
  xcrun notarytool submit "$1" --key "$APPLE_API_KEY" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER" --wait --timeout 30m
}

# Notarization takes a zip; the stapled app is zipped again for download.
mkdir -p dist
rm -f dist/PageOwl.zip dist/Books.zip
ditto -c -k --keepParent "$app" dist/PageOwl.zip
submit dist/PageOwl.zip
xcrun stapler staple "$app"
rm dist/PageOwl.zip
ditto -c -k --keepParent "$app" dist/PageOwl.zip

legacy=$(mktemp -d)
ditto "$app" "$legacy/Books.app"
ditto -c -k --keepParent "$legacy/Books.app" dist/Books.zip
rm -r "$legacy"

identity=$(codesign -dvv "$app" 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p' | head -1)
scripts/create-dmg.sh "$app" dist/PageOwl.dmg
codesign --force --timestamp --sign "$identity" dist/PageOwl.dmg
submit dist/PageOwl.dmg
xcrun stapler staple dist/PageOwl.dmg

spctl --assess --type execute "$app"
for f in PageOwl.zip PageOwl.dmg Books.zip; do
  (cd dist && shasum -a 256 "$f" > "$f.sha256")
done
echo "Notarized dist/PageOwl.zip and dist/PageOwl.dmg"
