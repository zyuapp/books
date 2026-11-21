# Books

A native macOS reader for EPUB, PDF, MOBI, AZW3, FB2, comic archives (CBZ, CBR, CB7, CBT), TXT, Markdown, RTF, DOCX, ODT and HTML.

- **Remembers your place**: every book reopens at the page you left, on every Mac signed in to your iCloud account.
- **Undo a jump**: after jumping by contents, link, search or the scrubber, ⌘Z takes you back.
- **Highlights, notes and bookmarks**, exportable as Markdown.
- **Ask ChatGPT** about a passage, the chapter or the whole book, with your own ChatGPT plan.
- **Two-page spreads**, eight reading themes and Liquid Glass on macOS 26.

Requires macOS 15 or later.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/zyuapp/books/main/install.sh | sh
```

Or download `Books.dmg` from the [latest release](https://github.com/zyuapp/books/releases/latest) and drag Books to Applications.

Books updates itself. It checks for new releases at launch and every 6 hours, downloads them in the background, and verifies the checksum and that the update is signed by the same developer. The update installs when Books quits, or by a quiet relaunch back onto the same page after Books has sat in the background for 10 minutes. **Books → Check for Updates…** checks right away.

To make Books the default for your books, open **Books → Settings → General → Make Books the Default for eBooks**.

## Your library

Books keeps your library in its own iCloud Drive folder, `iCloud Drive › Books` (or `~/Documents/Books/` without iCloud Drive). Reading positions, highlights, notes, ChatGPT conversations and settings sync through `Books/Reading Data/`. DRM-protected books can't be opened.

## Ask ChatGPT

Select text and press **Ask ChatGPT** (⌘L), or just ask about the book. ChatGPT can also work inside Books for you:

- **Look things up**: search the book, read any chapter, and read your highlights, notes and bookmarks across your whole library ("Which of my notes connect to this chapter?").
- **Act**: turn to a chapter or passage, highlight with a note, bookmark, edit or remove highlights, mark books finished, organise collections, and change the theme, font or layout.

Every change ChatGPT makes appears in the conversation with **Undo**.

Questions use your ChatGPT Plus or Pro plan through [Sign in with ChatGPT](https://developers.openai.com/siwc): press **Continue with ChatGPT** in the chat panel or in **Settings → ChatGPT**, and approve Books on OpenAI's website. Books never sees your password; its sign-in is kept in your Keychain. Review or limit Books' usage in [ChatGPT settings](https://chatgpt.com/settings/usage). ChatGPT gets only Books' own tools, which run inside the app, plus web search.

## Privacy and security

- Books never runs scripts that come inside a book, and blocks every network request a book makes. Pages render from local files only.
- Links in books can open web pages and mail drafts, never other apps.
- Nothing leaves your Mac except what you send to ChatGPT and what iCloud Drive syncs.

## Keyboard

| Keys | Action |
|---|---|
| ← → / Space / Page Up, Page Down | Turn pages |
| ⌥← ⌥→ | Previous / next chapter |
| ⌘Z, ⇧⌘Z | Undo / redo a jump |
| ⌘F | Find in book (in the library: search the library) |
| ⌥⌘T | Contents |
| ⌥⌘N | Highlights & bookmarks |
| ⌥⌘A | Reading settings |
| ⌘D | Bookmark |
| ⌘L | Ask ChatGPT |
| ⌘+ ⌘− ⌘0 | Text size |
| Esc | Close popups and panels, leave full screen, then return to the library |
| ⌘W | Close the book |

## Build from source

```sh
brew install xcodegen
scripts/install-local.sh        # builds build.noindex/Books.app and installs it in /Applications
```

Or run `xcodegen generate` and open `Books.xcodeproj`. `scripts/make-icon.swift` redraws the app icon.

To give ChatGPT a new ability, add an `AgentTool` to a catalog in `Books/Agent/AgentToolbox.swift`: a name, a description, typed parameters, and a handler that returns text for ChatGPT (and, for changes, an `AgentActivity` with an undo closure). `ChatGPTService` offers every tool in the catalog automatically.

Releases are cut with the **Release** workflow (`.github/workflows/release.yml`): it bumps `VERSION`, builds, signs with Developer ID, notarizes, and publishes `Books.zip` and `Books.dmg` with checksums.

## License

[MIT](LICENSE)
