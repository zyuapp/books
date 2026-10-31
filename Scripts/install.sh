#!/bin/zsh
# Builds a Release copy of Books and installs it into /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate >/dev/null
xcodebuild -project Books.xcodeproj -scheme Books -configuration Release -derivedDataPath build/DerivedData build | grep -E "error:|BUILD" || true
APP="build/DerivedData/Build/Products/Release/Books.app"
[[ -d "$APP" ]] || { echo "Build failed"; exit 1; }
pkill -x Books 2>/dev/null || true
rm -rf /Applications/Books.app
cp -R "$APP" /Applications/Books.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Books.app
echo "Installed /Applications/Books.app"
