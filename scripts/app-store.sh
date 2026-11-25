#!/bin/sh
# Builds the sandboxed Mac App Store package (APP_STORE: no self-updater) as dist/AppStore/PageOwl.pkg and, with
# PAGE_OWL_UPLOAD=1, uploads it to App Store Connect.
#
# Needs the "Apple Distribution" and "3rd Party Mac Developer Installer" identities in the keychain and
# Signing/PageOwl-AppStore.provisionprofile. Uploading needs an App Store Connect API key: APPLE_API_KEY (path to
# the .p8), APPLE_API_KEY_ID and APPLE_API_ISSUER.
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

version=${PAGE_OWL_VERSION:-$(cat VERSION)}
build=${PAGE_OWL_BUILD:-$(date +%Y%m%d%H%M)}
profile=Signing/PageOwl-AppStore.provisionprofile
entitlements=Signing/PageOwl-AppStore.entitlements
identity() { security find-identity -v | sed -n "s/.*\"\($1: [^\"]*\)\".*/\1/p" | head -1; }
app_identity=$(identity "Apple Distribution")
pkg_identity=$(identity "3rd Party Mac Developer Installer")
[ -n "$app_identity" ] || { echo "No Apple Distribution identity found" >&2; exit 1; }
[ -n "$pkg_identity" ] || { echo "No 3rd Party Mac Developer Installer identity found" >&2; exit 1; }

xcodegen generate --quiet
derived=build.noindex/AppStoreDD
xcodebuild -project PageOwl.xcodeproj -scheme PageOwl -configuration Release -derivedDataPath "$derived" \
  -destination 'generic/platform=macOS' ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" SWIFT_ACTIVE_COMPILATION_CONDITIONS=APP_STORE \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= -quiet build

out=dist/AppStore
app="$out/Page Owl.app"
rm -rf "$out"
mkdir -p "$out"
ditto "$derived/Build/Products/Release/Page Owl.app" "$app"
cp "$profile" "$app/Contents/embedded.provisionprofile"
codesign --force --options runtime --timestamp --entitlements "$entitlements" --sign "$app_identity" "$app"
codesign --verify --strict "$app"
productbuild --component "$app" /Applications --sign "$pkg_identity" "$out/PageOwl.pkg"
echo "Built $out/PageOwl.pkg ($version, build $build)"

if [ "${PAGE_OWL_UPLOAD:-0}" = 1 ]; then
  : "${APPLE_API_KEY:?}" "${APPLE_API_KEY_ID:?}" "${APPLE_API_ISSUER:?}"
  keys=$(mktemp -d)
  trap 'rm -rf "$keys"' EXIT
  cp "$APPLE_API_KEY" "$keys/AuthKey_$APPLE_API_KEY_ID.p8"
  API_PRIVATE_KEYS_DIR="$keys" xcrun altool --upload-package "$out/PageOwl.pkg" --type macos \
    --apiKey "$APPLE_API_KEY_ID" --apiIssuer "$APPLE_API_ISSUER"
fi
