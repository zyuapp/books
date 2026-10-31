# Books

A native macOS 26 reader for EPUB, PDF, MOBI, AZW3, FB2, CBZ/CBR/CB7/CBT, TXT, Markdown, RTF, DOCX, ODT and HTML.

- Library and reading state live in `iCloud Drive/Books/` (`Reading Data/` holds positions, highlights, notes and Claude chats).
- Ask Claude uses the local Claude Code CLI (`claude -p`), so it runs on your Claude subscription.

## Build

```sh
brew install xcodegen
xcodegen generate
open Books.xcodeproj        # or: Scripts/install.sh to build Release into /Applications
```

`Scripts/make-icon.swift` regenerates the app icon.
