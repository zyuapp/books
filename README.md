# Books

A native macOS reader for EPUB, PDF, MOBI, AZW3, FB2, comic archives (CBZ, CBR, CB7, CBT), TXT, Markdown, RTF, DOCX, ODT and HTML.

- **Remembers your place**: every book reopens at the page you left, on every Mac signed in to your iCloud account.
- **Undo a jump**: after jumping by contents, link, search or the scrubber, ⌘Z takes you back.
- **Highlights, notes and bookmarks**, exportable as Markdown.
- **Ask Claude** about a passage, the chapter or the whole book, through your own Claude Code sign-in.
- **Page-curl turns**, two-page spreads, eight reading themes and the macOS 26 Liquid Glass look.

Requires macOS 26.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/zyuapp/books/main/install.sh | sh
```

Or download `Books.dmg` from the [latest release](https://github.com/zyuapp/books/releases/latest) and drag Books to Applications. To make Books the default for your books, open **Books → Settings → General → Make Books the Default for eBooks**.

## Your library

Books keeps your library in `iCloud Drive/Books/` (or `~/Documents/Books/` without iCloud Drive). Reading positions, highlights, notes and Claude conversations sync through `Books/Reading Data/`. DRM-protected books can't be opened.

## Ask Claude

Select text and press **Ask Claude** (⌘L). Books runs the [Claude Code](https://docs.claude.com/en/docs/claude-code) CLI you already have installed in headless mode, with all tools disabled, so questions use your Claude subscription and Claude can only read the text Books sends it. Run `claude` once in Terminal to sign in first.

## Privacy and security

- Books never runs scripts that come inside a book, and blocks every network request a book makes. Pages render from local files only.
- Links in books can open web pages and mail drafts, never other apps.
- Nothing leaves your Mac except what you send to Claude and what iCloud Drive syncs.

## Keyboard

| Keys | Action |
|---|---|
| ← → / Space / Page Up, Page Down | Turn pages |
| ⌥← ⌥→ | Previous / next chapter |
| ⌘Z, ⇧⌘Z | Undo / redo a jump |
| ⌘F | Find in book (in the library: search the library) |
| ⌘D | Bookmark |
| ⌘L | Ask Claude |
| ⌘+ ⌘− ⌘0 | Text size |
| Esc | Close popups and panels, leave full screen, then return to the library |
| ⌘W | Close the book |

## Build from source

```sh
brew install xcodegen
scripts/install-local.sh        # builds dist/Books.app and installs it in /Applications
```

Or run `xcodegen generate` and open `Books.xcodeproj`. `scripts/make-icon.swift` redraws the app icon.

Releases are cut with the **Release** workflow (`.github/workflows/release.yml`): it bumps `VERSION`, builds, signs with Developer ID, notarizes, and publishes `Books.zip` and `Books.dmg` with checksums.

## License

[MIT](LICENSE)
