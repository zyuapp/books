#!/bin/sh
# Packages an app bundle into a drag-to-Applications DMG.
set -eu

app_path=${1:-build.noindex/Page Owl.app}
dmg_path=${2:-dist/PageOwl.dmg}
staging_dir=$(mktemp -d)

cleanup() {
  rm -r "$staging_dir"
}
trap cleanup EXIT

ditto "$app_path" "$staging_dir/Page Owl.app"
ln -s /Applications "$staging_dir/Applications"
mkdir -p "$(dirname "$dmg_path")"
hdiutil create \
  -quiet \
  -volname "Page Owl" \
  -srcfolder "$staging_dir" \
  -format UDZO \
  -ov \
  "$dmg_path"
echo "Created $dmg_path"
