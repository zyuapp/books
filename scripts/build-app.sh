#!/bin/sh
# Builds build.noindex/Books.app (universal). The .noindex suffix keeps build copies out of Spotlight.
#
# With Signing/Books.provisionprofile present, signs with Developer ID and the iCloud entitlements;
# otherwise signs ad-hoc, and the app keeps its library in ~/Documents/Books.
# Set BOOKS_RELEASE=1 to add the hardened runtime for scripts/notarize.sh (requires the profile),
# or BOOKS_SIGNING_IDENTITY to pick an identity.
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

version=${BOOKS_VERSION:-$(cat VERSION)}
build=${BOOKS_BUILD:-$(date +%Y%m%d%H%M)}
release=${BOOKS_RELEASE:-0}
identity=${BOOKS_SIGNING_IDENTITY:-}
profile=${BOOKS_PROVISIONING_PROFILE:-Signing/Books.provisionprofile}

[ "$release" = 1 ] && [ ! -f "$profile" ] && { echo "Missing $profile; releases need it for iCloud" >&2; exit 1; }
if [ -z "$identity" ] && { [ "$release" = 1 ] || [ -f "$profile" ]; }; then
  identity=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
  [ -n "$identity" ] || [ "$release" != 1 ] || { echo "No Developer ID Application certificate found" >&2; exit 1; }
fi
identity=${identity:--}

command -v xcodegen >/dev/null 2>&1 || { echo "XcodeGen is required: brew install xcodegen" >&2; exit 1; }
xcodegen generate --quiet

derived=build.noindex/DerivedData
xcodebuild -project Books.xcodeproj -scheme Books -configuration Release -derivedDataPath "$derived" \
  -destination 'generic/platform=macOS' ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  -quiet build

app=build.noindex/Books.app
rm -rf "$app"
ditto "$derived/Build/Products/Release/Books.app" "$app"

options=""
[ "$release" = 1 ] && options="--options runtime --timestamp"
if [ "$identity" != - ] && [ -f "$profile" ]; then
  cp "$profile" "$app/Contents/embedded.provisionprofile"
  options="$options --entitlements Signing/Books.entitlements"
fi
# shellcheck disable=SC2086
codesign --force $options --sign "$identity" "$app"
codesign --verify --strict "$app"
echo "Built $app ($version, signed: $identity)"
