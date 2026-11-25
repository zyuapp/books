#!/bin/sh
# Install the latest Page Owl release.
#
#   curl -fsSL https://raw.githubusercontent.com/zyuapp/page-owl/main/install.sh | sh
#
# Puts the notarized app in /Applications (or ~/Applications when that is not writable), replacing an
# install from before the app was renamed from Books.
set -eu

REPO="zyuapp/page-owl"
DOWNLOAD="https://github.com/$REPO/releases/latest/download"
BUNDLE_ID="com.zyu.books"

fail() { printf '\nInstall failed: %s\n' "$1" >&2; exit 1; }
say() { printf '%s\n' "$1"; }

[ "$(uname -s)" = Darwin ] || fail "Page Owl runs on macOS only."
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 15 ] || fail "Page Owl needs macOS 15 or later, and this Mac has $(sw_vers -productVersion)."
command -v curl >/dev/null 2>&1 || fail "curl is required."

applications=/Applications
[ -w "$applications" ] || applications="$HOME/Applications"
mkdir -p "$applications"
target="$applications/Page Owl.app"
legacy="$applications/Books.app"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$legacy/Contents/Info.plist" 2>/dev/null)" = "$BUNDLE_ID" ] \
  || legacy=""

# Stage inside the destination so the final move is a rename on the same filesystem.
staging="$applications/.page-owl-install.$$"
rm -rf "$staging"
mkdir "$staging"
trap 'rm -rf "$staging"' EXIT INT TERM

say "Downloading Page Owl."
curl -fL --retry 3 --progress-bar -o "$staging/PageOwl.zip" "$DOWNLOAD/PageOwl.zip" \
  || fail "The download did not finish."
expected="$(curl -fsSL "$DOWNLOAD/PageOwl.zip.sha256" | cut -d' ' -f1)" \
  || fail "Could not read the checksum of the latest release."
[ "$(shasum -a 256 "$staging/PageOwl.zip" | cut -d' ' -f1)" = "$expected" ] \
  || fail "The download did not match its checksum. Try again."

for app in "$target" ${legacy:+"$legacy"}; do
  if pgrep -f "$app/Contents/MacOS/" >/dev/null 2>&1; then
    fail "$(basename "$app" .app) is running. Quit it, then run this again."
  fi
done
/usr/bin/ditto -x -k "$staging/PageOwl.zip" "$staging/unpacked" || fail "The download could not be unpacked."
[ -d "$staging/unpacked/Page Owl.app" ] || fail "The download contained no app."
/usr/sbin/spctl --assess --type execute "$staging/unpacked/Page Owl.app" 2>/dev/null \
  || fail "The download is not a notarized build of Page Owl."
rm -rf "$target"
mv "$staging/unpacked/Page Owl.app" "$target"
[ -n "$legacy" ] && rm -rf "$legacy"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$target/Contents/Info.plist" 2>/dev/null || echo latest)"
say "Installed Page Owl $version in $target"
