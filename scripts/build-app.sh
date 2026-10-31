#!/bin/sh
# Builds dist/Books.app (universal).
#
# Signs ad-hoc by default, which macOS runs without a Gatekeeper prompt when built on this Mac.
# Set BOOKS_RELEASE=1 to sign with Developer ID and the hardened runtime for scripts/notarize.sh,
# or BOOKS_SIGNING_IDENTITY to pick an identity.
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

version=${BOOKS_VERSION:-$(cat VERSION)}
build=${BOOKS_BUILD:-$(date +%Y%m%d%H%M)}
release=${BOOKS_RELEASE:-0}
identity=${BOOKS_SIGNING_IDENTITY:-}

if [ -z "$identity" ] && [ "$release" = 1 ]; then
  identity=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
  [ -n "$identity" ] || { echo "No Developer ID Application certificate found" >&2; exit 1; }
fi
identity=${identity:--}

command -v xcodegen >/dev/null 2>&1 || { echo "XcodeGen is required: brew install xcodegen" >&2; exit 1; }
xcodegen generate --quiet

derived=build/DerivedData
xcodebuild -project Books.xcodeproj -scheme Books -configuration Release -derivedDataPath "$derived" \
  -destination 'generic/platform=macOS' ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  -quiet build

app=dist/Books.app
rm -rf "$app"
mkdir -p dist
ditto "$derived/Build/Products/Release/Books.app" "$app"

options=""
[ "$release" = 1 ] && options="--options runtime --timestamp"
# shellcheck disable=SC2086
codesign --force $options --sign "$identity" "$app"
codesign --verify --strict "$app"
echo "Built $app ($version, signed: $identity)"
