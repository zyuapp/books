#!/bin/sh
# Builds Page Owl from source and installs it in /Applications.
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
scripts/build-app.sh
pkill -x "Page Owl" 2>/dev/null || true
rm -rf "/Applications/Page Owl.app"
ditto "build.noindex/Page Owl.app" "/Applications/Page Owl.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/Page Owl.app"
echo "Installed /Applications/Page Owl.app"
