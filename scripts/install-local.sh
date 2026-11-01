#!/bin/sh
# Builds Books from source and installs it in /Applications.
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
scripts/build-app.sh
pkill -x Books 2>/dev/null || true
rm -rf /Applications/Books.app
ditto build.noindex/Books.app /Applications/Books.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Books.app
echo "Installed /Applications/Books.app"
