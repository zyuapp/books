#!/bin/sh
# Install the latest Books release.
#
#   curl -fsSL https://raw.githubusercontent.com/zyuapp/books/main/install.sh | sh
#
# Puts the notarized app in /Applications (or ~/Applications when that is not writable).
set -eu

REPO="zyuapp/books"
DOWNLOAD="https://github.com/$REPO/releases/latest/download"

fail() { printf '\nInstall failed: %s\n' "$1" >&2; exit 1; }
say() { printf '%s\n' "$1"; }

[ "$(uname -s)" = Darwin ] || fail "Books runs on macOS only."
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 15 ] || fail "Books needs macOS 15 or later, and this Mac has $(sw_vers -productVersion)."
command -v curl >/dev/null 2>&1 || fail "curl is required."

applications=/Applications
[ -w "$applications" ] || applications="$HOME/Applications"
mkdir -p "$applications"

# Stage inside the destination so the final move is a rename on the same filesystem.
staging="$applications/.books-install.$$"
rm -rf "$staging"
mkdir "$staging"
trap 'rm -rf "$staging"' EXIT INT TERM

say "Downloading Books."
curl -fL --retry 3 --progress-bar -o "$staging/Books.zip" "$DOWNLOAD/Books.zip" \
  || fail "The download did not finish."
expected="$(curl -fsSL "$DOWNLOAD/Books.zip.sha256" | cut -d' ' -f1)" \
  || fail "Could not read the checksum of the latest release."
[ "$(shasum -a 256 "$staging/Books.zip" | cut -d' ' -f1)" = "$expected" ] \
  || fail "The download did not match its checksum. Try again."

if pgrep -f "$applications/Books.app/Contents/MacOS/Books" >/dev/null 2>&1; then
  fail "Books is running. Quit it, then run this again."
fi
/usr/bin/ditto -x -k "$staging/Books.zip" "$staging/unpacked" || fail "The download could not be unpacked."
[ -d "$staging/unpacked/Books.app" ] || fail "The download contained no app."
/usr/sbin/spctl --assess --type execute "$staging/unpacked/Books.app" 2>/dev/null \
  || fail "The download is not a notarized build of Books."
target="$applications/Books.app"
rm -rf "$target"
mv "$staging/unpacked/Books.app" "$target"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$target/Contents/Info.plist" 2>/dev/null || echo latest)"
say "Installed Books $version in $target"
