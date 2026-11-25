#!/bin/sh
# Archives the sandboxed Mac App Store build (APP_STORE: no self-updater) and uploads it to App Store Connect.
# Signs through Xcode's automatic (cloud) signing: with APPLE_API_KEY (path to the .p8), APPLE_API_KEY_ID and
# APPLE_API_ISSUER set, as an App Store Connect API key; otherwise as the Apple account signed in to Xcode.
# Set PAGE_OWL_UPLOAD=0 to export a signed .pkg to dist/AppStore instead of uploading.
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

team=T3Y739SK63
version=${PAGE_OWL_VERSION:-$(cat VERSION)}
build=${PAGE_OWL_BUILD:-$(date +%Y%m%d%H%M)}
destination=upload
[ "${PAGE_OWL_UPLOAD:-1}" = 1 ] || destination=export

auth=""
[ -n "${APPLE_API_KEY:-}" ] && auth="-authenticationKeyPath $APPLE_API_KEY -authenticationKeyID $APPLE_API_KEY_ID -authenticationKeyIssuerID $APPLE_API_ISSUER"

xcodegen generate --quiet
archive=build.noindex/AppStore/PageOwl.xcarchive
rm -rf "$archive"
xcodebuild archive -project PageOwl.xcodeproj -scheme PageOwl -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$archive" -allowProvisioningUpdates $auth \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS=APP_STORE ENABLE_APP_SANDBOX=YES \
  CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM="$team" \
  CODE_SIGN_ENTITLEMENTS=Signing/PageOwl-AppStore.entitlements -quiet

options=$(mktemp)
trap 'rm -f "$options"' EXIT
cat > "$options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$destination</string>
  <key>teamID</key><string>$team</string>
  <key>signingStyle</key><string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$options" \
  -exportPath dist/AppStore -allowProvisioningUpdates $auth
echo "App Store build $version ($build): $destination done"
