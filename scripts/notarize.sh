#!/bin/sh
# Notarizes and staples build.noindex/Books.app, then writes the release assets to dist/:
# Books.zip and Books.dmg, each with a .sha256 file.
#
# Needs an App Store Connect API key: APPLE_API_KEY (path to the .p8), APPLE_API_KEY_ID and
# APPLE_API_ISSUER. The app must already be signed with Developer ID (BOOKS_RELEASE=1).
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

app=build.noindex/Books.app
[ -d "$app" ] || { echo "Missing $app; run scripts/build-app.sh first" >&2; exit 1; }
: "${APPLE_API_KEY:?}" "${APPLE_API_KEY_ID:?}" "${APPLE_API_ISSUER:?}"

submit() {
  xcrun notarytool submit "$1" --key "$APPLE_API_KEY" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER" --wait --timeout 30m
}

# Notarization takes a zip; the stapled app is zipped again for download.
mkdir -p dist
rm -f dist/Books.zip
ditto -c -k --keepParent "$app" dist/Books.zip
submit dist/Books.zip
xcrun stapler staple "$app"
rm dist/Books.zip
ditto -c -k --keepParent "$app" dist/Books.zip

identity=$(codesign -dvv "$app" 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p' | head -1)
scripts/create-dmg.sh "$app" dist/Books.dmg
codesign --force --timestamp --sign "$identity" dist/Books.dmg
submit dist/Books.dmg
xcrun stapler staple dist/Books.dmg

spctl --assess --type execute "$app"
for f in Books.zip Books.dmg; do
  (cd dist && shasum -a 256 "$f" > "$f.sha256")
done
echo "Notarized dist/Books.zip and dist/Books.dmg"
