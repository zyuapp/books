import AppKit
import Foundation

/// Every tool Claude can use in Books, grouped by area. Add a tool to one of the catalogs to expose it.
@MainActor
enum AgentToolbox {
    static let all: [AgentTool] = ReadingTools.all + NotesTools.all + NavigationTools.all + AnnotationTools.all
        + LibraryTools.all + SettingsTools.all

    static func tool(named name: String) -> AgentTool? { all.first { $0.name == name } }

    /// One-paragraph guide appended to Claude's system prompt.
    static let guidance = """
    You can use the Books tools to look things up and act inside the app: read and search the book, read the \
    reader's highlights, notes and bookmarks across their whole library, move around the book, create or edit \
    highlights, notes and bookmarks, organise books into collections, and change reading settings. Use them \
    whenever they help answer the reader, for example to cross-reference their notes. Never invent ids; get \
    them from the list tools. When you change something, say briefly what you did; the reader can undo it.
    """
}

// MARK: - Shared helpers

@MainActor
enum AgentSupport {
    static let library = LibraryStore.shared

    /// Resolves `book_id` ("current", omitted, or a library id) to a book id.
    static func bookID(_ args: ToolArguments, _ session: AgentSession) throws -> String {
        if let id = args.string("book_id"), id != "current" {
            guard library.book(id) != nil || library.states[id] != nil else {
                throw ToolError.notFound("No book with id \(id). Use list_library to find ids.")
            }
            return id
        }
        guard let reader = session.reader else { throw ToolError.unavailable("No book is open.") }
        return reader.book.id
    }

    static func title(_ id: String) -> String {
        library.state(id).title ?? library.book(id)?.url.deletingPathExtension().lastPathComponent ?? id
    }

    /// Flattened table of contents, numbered from 1.
    static func chapters(_ publication: Publication) -> [TOCEntry] {
        ReaderModel.flatten(publication.toc)
    }

    /// Plain text per spine item for any book; the open book's text comes from its reader cache.
    static func texts(bookID: String, session: AgentSession) async throws -> (Publication, [String]) {
        if let reader = session.reader, reader.book.id == bookID, let pub = reader.publication {
            return (pub, await reader.bookTexts())
        }
        guard let book = library.book(bookID) else { throw ToolError.unavailable("That book isn’t available on this Mac.") }
        if !book.isDownloaded { try await library.ensureDownloaded(book) }
        let url = book.url
        return try await Task.detached(priority: .userInitiated) {
            let pub = try BookLoader.load(url, bookID: bookID)
            return (pub, TextExtractor.texts(for: pub, bookID: bookID))
        }.value
    }

    static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "[\u{2018}\u{2019}]", with: "'", options: .regularExpression)
            .replacingOccurrences(of: "[\u{201C}\u{201D}]", with: "\"", options: .regularExpression)
            .replacingOccurrences(of: "\u{00AD}", with: "")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    /// The spine item containing `quote`, preferring the one being read.
    static func spineIndex(containing quote: String, in texts: [String], prefer: Int) -> Int? {
        let q = normalize(quote)
        guard !q.isEmpty else { return nil }
        if texts.indices.contains(prefer), normalize(texts[prefer]).contains(q) { return prefer }
        return texts.indices.first { normalize(texts[$0]).contains(q) }
    }

    static func clip(_ s: String, _ n: Int) -> String {
        let t = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return t.count > n ? String(t.prefix(n)) + "…" : t
    }

    static func percent(_ p: Double) -> String { "\(Int((p * 100).rounded()))%" }
}

// MARK: - Reading

@MainActor
enum ReadingTools {
    static let all: [AgentTool] = [context, tableOfContents, readText, searchText]

    static let context = AgentTool(
        name: "get_reading_context",
        description: "What the reader is looking at right now: book, chapter, position, selected text and the start of the visible page.",
        kind: .read, progress: "Looking at your page"
    ) { _, session in
        let reader = try session.requireReader()
        let snippet = await reader.engine?.currentSnippet() ?? ""
        var lines = [
            "Book: \(reader.title)" + (reader.publication?.author.map { " by \($0)" } ?? ""),
            "Book id: \(reader.book.id)",
            "Format: \(reader.book.format.displayName)",
            "Position: \(ReaderModel.describe(reader.location, publication: reader.publication))",
        ]
        if let chapter = reader.chapterTitle { lines.append("Chapter: \(chapter)") }
        if reader.publication?.kind == .reflowable {
            lines.append("Page \(reader.pageInChapter + 1) of \(reader.pagesInChapter) in this chapter")
        }
        if let selection = reader.selection?.text { lines.append("Selected text: \(AgentSupport.clip(selection, 1500))") }
        if !snippet.isEmpty { lines.append("Visible page starts: \(snippet)") }
        return .text(lines.joined(separator: "\n"))
    }

    static let tableOfContents = AgentTool(
        name: "get_table_of_contents",
        description: "The book's chapters, numbered. Use the numbers with read_text and go_to.",
        kind: .read, progress: "Reading the contents",
        parameters: [.init(name: "book_id", type: .string, description: "A book id from list_library; defaults to the open book.")]
    ) { args, session in
        let id = try AgentSupport.bookID(args, session)
        let pub: Publication
        if let reader = session.reader, reader.book.id == id, let p = reader.publication { pub = p }
        else { pub = try await AgentSupport.texts(bookID: id, session: session).0 }
        let entries = AgentSupport.chapters(pub)
        guard !entries.isEmpty else { return .text("This book has no table of contents (\(pub.spine.count) sections).") }
        let current = session.reader?.book.id == id ? session.reader?.location.index : nil
        return .text(entries.enumerated().map { i, e in
            "\(i + 1). \(e.title)" + (pub.kind == .reflowable ? "" : " (page \(e.spineIndex + 1))") + (e.spineIndex == current ? "  ← reading" : "")
        }.joined(separator: "\n"))
    }

    static let readText = AgentTool(
        name: "read_text",
        description: "Read the text of a chapter (by number from get_table_of_contents), or the current chapter. Works for any book in the library.",
        kind: .read, progress: "Reading",
        parameters: [
            .init(name: "chapter", type: .integer, description: "Chapter number from get_table_of_contents. Omit for the current chapter."),
            .init(name: "book_id", type: .string, description: "A book id from list_library; defaults to the open book."),
            .init(name: "max_characters", type: .integer, description: "Upper limit on returned text (default 40000)."),
        ]
    ) { args, session in
        let id = try AgentSupport.bookID(args, session)
        let (pub, texts) = try await AgentSupport.texts(bookID: id, session: session)
        let entries = AgentSupport.chapters(pub)
        let limit = min(max(args.int("max_characters") ?? 40_000, 500), 200_000)
        var range: Range<Int>
        var label: String
        if let n = args.int("chapter") {
            guard entries.indices.contains(n - 1) else { throw ToolError.invalid("Chapter \(n) doesn’t exist; there are \(entries.count).") }
            let start = entries[n - 1].spineIndex
            let next = entries.map(\.spineIndex).filter { $0 > start }.min() ?? texts.count
            range = start..<max(start + 1, next)
            label = entries[n - 1].title
        } else {
            let index = session.reader?.book.id == id ? (session.reader?.location.index ?? 0) : 0
            let entry = pub.tocEntry(forSpineIndex: index)
            let start = entry?.spineIndex ?? index
            let next = entries.map(\.spineIndex).filter { $0 > start }.min() ?? texts.count
            range = start..<max(start + 1, min(next, start + (pub.kind == .reflowable ? 1 : 40)))
            label = entry?.title ?? "Current section"
        }
        range = range.clamped(to: 0..<texts.count)
        let body = range.map { i in pub.kind == .pdf ? "[Page \(i + 1)]\n\(texts[i])" : texts[i] }.joined(separator: "\n\n")
        let clipped = body.count > limit ? String(body.prefix(limit)) + "\n[…truncated]" : body
        return .text("\(AgentSupport.title(id)) — \(label)\n\n\(clipped)")
    }

    static let searchText = AgentTool(
        name: "search_text",
        description: "Search the words of a book. Results are numbered; pass a number to go_to(search_result:) to show it in the open book.",
        kind: .read, progress: "Searching the book",
        parameters: [
            .init(name: "query", type: .string, description: "Words to find.", required: true),
            .init(name: "book_id", type: .string, description: "A book id from list_library; defaults to the open book."),
            .init(name: "limit", type: .integer, description: "Most results to return (default 20)."),
        ]
    ) { args, session in
        let query = try args.require("query")
        let id = try AgentSupport.bookID(args, session)
        let (pub, texts) = try await AgentSupport.texts(bookID: id, session: session)
        let limit = min(max(args.int("limit") ?? 20, 1), 100)
        let results = TextExtractor.search(query, in: texts, publication: pub, limit: 500)
        if session.reader?.book.id == id {
            session.lastSearch = results
            session.lastSearchQuery = query
        }
        guard !results.isEmpty else { return .text("No matches for “\(query)”.") }
        let lines = results.prefix(limit).enumerated().map { i, r in
            "\(i + 1). [\(r.chapter.isEmpty ? AgentSupport.percent(r.locator.totalProgress) : r.chapter)] \(String(r.snippet.characters))"
        }
        return .text("\(results.count) matches in \(AgentSupport.title(id)):\n" + lines.joined(separator: "\n"))
    }
}

// MARK: - Notes, highlights and bookmarks

@MainActor
enum NotesTools {
    static let all: [AgentTool] = [listHighlights, listBookmarks, exportNotes]

    static let listHighlights = AgentTool(
        name: "list_highlights",
        description: "The reader's highlights and notes, for the open book, one book, or the whole library. Each has an id for edit_highlight, delete_highlight and go_to.",
        kind: .read, progress: "Reading your highlights",
        parameters: [
            .init(name: "book_id", type: .string, description: "\"current\" (default), \"all\" for every book, or a book id."),
            .init(name: "query", type: .string, description: "Only highlights whose text or note contains this."),
            .init(name: "color", type: .string, description: "Only this color.", options: HighlightColor.allCases.map(\.rawValue)),
            .init(name: "notes_only", type: .boolean, description: "Only highlights that have a note."),
        ]
    ) { args, session in
        let ids: [String] = args.string("book_id") == "all"
            ? Array(AgentSupport.library.states.keys)
            : [try AgentSupport.bookID(args, session)]
        let query = args.string("query").map(AgentSupport.normalize)
        var lines: [String] = []
        for id in ids.sorted(by: { AgentSupport.title($0) < AgentSupport.title($1) }) {
            let hs = AgentSupport.library.state(id).liveHighlights
                .filter { args.string("color") == nil || $0.color.rawValue == args.string("color") }
                .filter { args.bool("notes_only") != true || !($0.note ?? "").isEmpty }
                .filter { h in query.map { AgentSupport.normalize(h.text + " " + (h.note ?? "")).contains($0) } ?? true }
                .sorted { $0.locator.totalProgress < $1.locator.totalProgress }
            guard !hs.isEmpty else { continue }
            lines.append("## \(AgentSupport.title(id)) (book id \(id))")
            for h in hs.prefix(300) {
                var line = "- id \(h.id.uuidString) [\(h.color.rawValue), \(h.locator.label ?? AgentSupport.percent(h.locator.totalProgress))] “\(AgentSupport.clip(h.text, 600))”"
                if let note = h.note, !note.isEmpty { line += "\n  Note: \(AgentSupport.clip(note, 800))" }
                lines.append(line)
            }
        }
        return .text(lines.isEmpty ? "No highlights found." : lines.joined(separator: "\n"))
    }

    static let listBookmarks = AgentTool(
        name: "list_bookmarks",
        description: "The reader's bookmarks, for the open book, one book, or the whole library.",
        kind: .read, progress: "Reading your bookmarks",
        parameters: [.init(name: "book_id", type: .string, description: "\"current\" (default), \"all\", or a book id.")]
    ) { args, session in
        let ids: [String] = args.string("book_id") == "all"
            ? Array(AgentSupport.library.states.keys)
            : [try AgentSupport.bookID(args, session)]
        var lines: [String] = []
        for id in ids {
            let bs = AgentSupport.library.state(id).liveBookmarks.sorted { $0.locator.totalProgress < $1.locator.totalProgress }
            guard !bs.isEmpty else { continue }
            lines.append("## \(AgentSupport.title(id)) (book id \(id))")
            lines += bs.map { "- id \($0.id.uuidString) [\($0.locator.label ?? AgentSupport.percent($0.locator.totalProgress))] \(AgentSupport.clip($0.snippet, 300))" }
        }
        return .text(lines.isEmpty ? "No bookmarks." : lines.joined(separator: "\n"))
    }

    static let exportNotes = AgentTool(
        name: "export_notes",
        description: "The open book's highlights, notes and bookmarks as Markdown, optionally copied to the clipboard.",
        kind: .read, progress: "Collecting your notes",
        parameters: [.init(name: "copy", type: .boolean, description: "Also copy the Markdown to the clipboard.")]
    ) { args, session in
        let reader = try session.requireReader()
        let md = reader.notesMarkdown()
        guard args.bool("copy") == true else { return .text(md) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(md, forType: .string)
        return ToolResult(text: md, activity: AgentActivity(symbol: "doc.on.clipboard", title: "Copied your notes as Markdown"))
    }
}

// MARK: - Navigation

@MainActor
enum NavigationTools {
    static let all: [AgentTool] = [goTo, turnPages, goBack, showPanel]

    static let goTo = AgentTool(
        name: "go_to",
        description: "Move the open book to a place. Give exactly one of: chapter, percent, page, highlight_id, bookmark_id, search_result, quote. The reader can go back with ⌘Z.",
        kind: .navigate, progress: "Turning to the page",
        parameters: [
            .init(name: "chapter", type: .integer, description: "Chapter number from get_table_of_contents."),
            .init(name: "percent", type: .number, description: "Position through the book, 0–100."),
            .init(name: "page", type: .integer, description: "Page number (PDFs and comics)."),
            .init(name: "highlight_id", type: .string, description: "A highlight id from list_highlights (open book)."),
            .init(name: "bookmark_id", type: .string, description: "A bookmark id from list_bookmarks (open book)."),
            .init(name: "search_result", type: .integer, description: "A result number from the last search_text."),
            .init(name: "quote", type: .string, description: "A passage to find and show."),
        ]
    ) { args, session in
        let reader = try session.requireReader()
        guard let pub = reader.publication else { throw ToolError.unavailable("The book is still opening.") }
        var said: String
        if let n = args.int("chapter") {
            let entries = AgentSupport.chapters(pub)
            guard entries.indices.contains(n - 1) else { throw ToolError.invalid("Chapter \(n) doesn’t exist; there are \(entries.count).") }
            reader.go(to: entries[n - 1])
            said = "Opened \(entries[n - 1].title)"
        } else if let p = args.double("percent") {
            reader.jump(toProgress: min(max(p / 100, 0), 1))
            said = "Moved to \(Int(p))%"
        } else if let page = args.int("page") {
            guard pub.kind != .reflowable else { throw ToolError.invalid("This book has chapters, not fixed pages; use chapter or percent.") }
            reader.jump(to: Locator(index: min(max(page - 1, 0), pub.spine.count - 1)))
            said = "Moved to page \(page)"
        } else if let id = args.uuid("highlight_id") {
            guard let h = reader.state.liveHighlights.first(where: { $0.id == id }) else { throw ToolError.notFound("No highlight with that id in this book.") }
            reader.jump(to: h.locator)
            said = "Showing your highlight “\(AgentSupport.clip(h.text, 60))”"
        } else if let id = args.uuid("bookmark_id") {
            guard let b = reader.state.liveBookmarks.first(where: { $0.id == id }) else { throw ToolError.notFound("No bookmark with that id in this book.") }
            reader.jump(to: b.locator)
            said = "Opened your bookmark"
        } else if let n = args.int("search_result") {
            guard session.lastSearch.indices.contains(n - 1) else { throw ToolError.invalid("Run search_text first, then pick a result number.") }
            reader.searchQuery = session.lastSearchQuery
            reader.reveal(session.lastSearch[n - 1])
            said = "Showing search result \(n)"
        } else if let quote = args.string("quote") {
            let texts = await reader.bookTexts()
            let results = TextExtractor.search(quote, in: texts, publication: pub, limit: 50)
            guard let hit = results.first(where: { $0.locator.index == reader.location.index }) ?? results.first else {
                throw ToolError.notFound("Couldn’t find that passage in the book.")
            }
            reader.searchQuery = quote
            reader.reveal(hit)
            said = "Showing “\(AgentSupport.clip(quote, 60))”"
        } else {
            throw ToolError.invalid("Give one of chapter, percent, page, highlight_id, bookmark_id, search_result or quote.")
        }
        let activity = AgentActivity(symbol: "arrow.turn.down.right", title: said, undoLabel: "Go Back") { [weak reader] in reader?.goBack() }
        return ToolResult(text: said + ".", activity: activity)
    }

    static let turnPages = AgentTool(
        name: "turn_pages",
        description: "Turn pages in the open book: positive goes forward, negative goes back (up to 20).",
        kind: .navigate, progress: "Turning pages",
        parameters: [.init(name: "count", type: .integer, description: "Pages to turn, e.g. 1 or -2.", required: true)]
    ) { args, session in
        let reader = try session.requireReader()
        let count = min(max(args.int("count") ?? 1, -20), 20)
        for _ in 0..<abs(count) { count > 0 ? reader.nextPage() : reader.previousPage() }
        return .text("Turned \(abs(count)) page\(abs(count) == 1 ? "" : "s") \(count > 0 ? "forward" : "back").")
    }

    static let goBack = AgentTool(
        name: "go_back",
        description: "Undo the last jump in the open book, returning to where the reader was.",
        kind: .navigate, progress: "Going back"
    ) { _, session in
        let reader = try session.requireReader()
        guard reader.canGoBack else { return .text("There’s nowhere to go back to.") }
        reader.goBack()
        return .text("Went back to \(ReaderModel.describe(reader.location, publication: reader.publication)).")
    }

    static let showPanel = AgentTool(
        name: "show_panel",
        description: "Open a side panel for the reader: contents, notes (highlights and bookmarks) or search (optionally with a query), or close it.",
        kind: .navigate, progress: "Opening the panel",
        parameters: [
            .init(name: "panel", type: .string, description: "Which panel.", required: true, options: ["contents", "notes", "search", "none"]),
            .init(name: "search_query", type: .string, description: "Words to search for when opening search."),
        ]
    ) { args, session in
        let reader = try session.requireReader()
        switch args.string("panel") {
        case "contents": reader.panel = .contents
        case "notes": reader.panel = .notes
        case "search":
            reader.panel = .search
            if let q = args.string("search_query") { reader.searchQuery = q; reader.search(q) }
        default: reader.panel = nil
        }
        return .text("Done.")
    }
}

// MARK: - Highlights, notes and bookmarks (changes)

@MainActor
enum AnnotationTools {
    static let all: [AgentTool] = [addHighlight, editHighlight, deleteHighlight, addBookmark, deleteBookmark]

    static let addHighlight = AgentTool(
        name: "add_highlight",
        description: "Highlight a passage in the open book, optionally with a note. Quote the passage exactly as it appears (a sentence or phrase); the book turns to it.",
        kind: .change, progress: "Highlighting",
        parameters: [
            .init(name: "quote", type: .string, description: "The exact passage to highlight.", required: true),
            .init(name: "color", type: .string, description: "Highlight color (default yellow).", options: HighlightColor.allCases.map(\.rawValue)),
            .init(name: "note", type: .string, description: "A note to attach."),
        ]
    ) { args, session in
        let reader = try session.requireReader()
        guard let pub = reader.publication, pub.kind != .comic else { throw ToolError.unavailable("Comics have no text to highlight.") }
        let quote = try args.require("quote")
        if pub.kind == .reflowable {
            let texts = await reader.bookTexts()
            guard let spine = AgentSupport.spineIndex(containing: quote, in: texts, prefer: reader.location.index) else {
                throw ToolError.notFound("Couldn’t find that exact passage. Quote it word for word, or search_text for it first.")
            }
            if spine != reader.location.index { reader.jump(to: Locator(index: spine)) }
            await reader.engine?.waitUntilContentReady()
        }
        guard let target = await reader.engine?.locate(quote) else {
            throw ToolError.notFound("Couldn’t find that exact passage on the page. Quote it word for word.")
        }
        if pub.kind == .pdf, target.index != reader.location.index { reader.jump(to: Locator(index: target.index)) }
        let locator = Locator(index: target.index, progression: target.progression,
                              totalProgress: pub.progress(spineIndex: target.index, progression: target.progression),
                              label: pub.kind == .reflowable ? pub.tocEntry(forSpineIndex: target.index)?.title : "Page \(target.index + 1)")
        let color = HighlightColor(rawValue: args.string("color") ?? "") ?? .yellow
        let h = Highlight(locator: locator, text: target.text, note: args.string("note"), color: color,
                          range: target.range, pdfRects: target.pdfRects)
        reader.addHighlight(h)
        let title = "Highlighted “\(AgentSupport.clip(h.text, 70))”" + (h.note == nil ? "" : " with a note")
        let activity = AgentActivity(symbol: "highlighter", title: title) { [weak reader] in reader?.deleteHighlight(h.id) }
        return ToolResult(text: "Highlighted (id \(h.id.uuidString)).", activity: activity)
    }

    static let editHighlight = AgentTool(
        name: "edit_highlight",
        description: "Change a highlight's color or note (in any book). An empty note removes it.",
        kind: .change, progress: "Updating the highlight",
        parameters: [
            .init(name: "highlight_id", type: .string, description: "Id from list_highlights.", required: true),
            .init(name: "color", type: .string, description: "New color.", options: HighlightColor.allCases.map(\.rawValue)),
            .init(name: "note", type: .string, description: "New note text; empty string removes the note."),
        ]
    ) { args, session in
        guard let id = args.uuid("highlight_id") else { throw ToolError.missing("highlight_id") }
        let (bookID, old) = try findHighlight(id)
        let newNote: String?? = args.raw["note"] == nil ? .none : .some(args.string("note"))
        let newColor = args.string("color").flatMap(HighlightColor.init(rawValue:))
        change(bookID, id, session) { h in
            if let newColor { h.color = newColor }
            if let newNote { h.note = newNote }
        }
        let activity = AgentActivity(symbol: "pencil", title: "Updated highlight “\(AgentSupport.clip(old.text, 60))”") {
            change(bookID, id, session) { h in h.color = old.color; h.note = old.note }
        }
        return ToolResult(text: "Updated.", activity: activity)
    }

    static let deleteHighlight = AgentTool(
        name: "delete_highlight",
        description: "Remove a highlight and its note (in any book).",
        kind: .change, progress: "Removing the highlight",
        parameters: [.init(name: "highlight_id", type: .string, description: "Id from list_highlights.", required: true)]
    ) { args, session in
        guard let id = args.uuid("highlight_id") else { throw ToolError.missing("highlight_id") }
        let (bookID, old) = try findHighlight(id)
        change(bookID, id, session) { $0.deleted = true }
        let activity = AgentActivity(symbol: "trash", title: "Removed highlight “\(AgentSupport.clip(old.text, 60))”") {
            change(bookID, id, session) { $0.deleted = false }
        }
        return ToolResult(text: "Removed.", activity: activity)
    }

    static let addBookmark = AgentTool(
        name: "add_bookmark",
        description: "Bookmark the page the open book is showing (use go_to first to bookmark somewhere else).",
        kind: .change, progress: "Bookmarking",
        parameters: [.init(name: "label", type: .string, description: "Optional text to show for the bookmark instead of the page's first words.")]
    ) { args, session in
        let reader = try session.requireReader()
        await reader.engine?.waitUntilContentReady()
        let snippet = await reader.engine?.currentSnippet() ?? ""
        let b = Bookmark(locator: reader.location, snippet: args.string("label") ?? (snippet.isEmpty ? ReaderModel.describe(reader.location, publication: reader.publication) : snippet))
        reader.addBookmark(b)
        let activity = AgentActivity(symbol: "bookmark", title: "Bookmarked \(ReaderModel.describe(b.locator, publication: reader.publication))") { [weak reader] in
            reader?.setBookmarkDeleted(b.id, true)
        }
        return ToolResult(text: "Bookmarked (id \(b.id.uuidString)).", activity: activity)
    }

    static let deleteBookmark = AgentTool(
        name: "delete_bookmark",
        description: "Remove a bookmark from the open book.",
        kind: .change, progress: "Removing the bookmark",
        parameters: [.init(name: "bookmark_id", type: .string, description: "Id from list_bookmarks.", required: true)]
    ) { args, session in
        let reader = try session.requireReader()
        guard let id = args.uuid("bookmark_id"), reader.state.liveBookmarks.contains(where: { $0.id == id }) else {
            throw ToolError.notFound("No bookmark with that id in this book.")
        }
        reader.setBookmarkDeleted(id, true)
        let activity = AgentActivity(symbol: "bookmark.slash", title: "Removed a bookmark") { [weak reader] in reader?.setBookmarkDeleted(id, false) }
        return ToolResult(text: "Removed.", activity: activity)
    }

    private static func findHighlight(_ id: UUID) throws -> (String, Highlight) {
        for (bookID, state) in AgentSupport.library.states {
            if let h = state.liveHighlights.first(where: { $0.id == id }) { return (bookID, h) }
        }
        throw ToolError.notFound("No highlight with that id. Use list_highlights to find ids.")
    }

    private static func change(_ bookID: String, _ id: UUID, _ session: AgentSession, _ body: @escaping (inout Highlight) -> Void) {
        if let reader = session.reader, reader.book.id == bookID {
            reader.updateHighlight(id, body)
        } else {
            AgentSupport.library.update(bookID) { s in
                guard let i = s.highlights.firstIndex(where: { $0.id == id }) else { return }
                body(&s.highlights[i])
                s.highlights[i].updated = Date()
            }
        }
    }
}

// MARK: - Library

@MainActor
enum LibraryTools {
    static let all: [AgentTool] = [listLibrary, setStatus, setCollections]

    static let listLibrary = AgentTool(
        name: "list_library",
        description: "Books in the reader's library with ids, authors, progress, status, collections and highlight counts.",
        kind: .read, progress: "Looking through your library",
        parameters: [
            .init(name: "query", type: .string, description: "Only books whose title or author contains this."),
            .init(name: "status", type: .string, description: "Only books with this status.", options: ReadingStatus.allCases.map(\.rawValue)),
            .init(name: "collection", type: .string, description: "Only books in this collection."),
        ]
    ) { args, _ in
        let lib = AgentSupport.library
        let q = args.string("query").map(AgentSupport.normalize)
        let rows = lib.books.compactMap { book -> String? in
            let s = lib.state(book.id)
            let title = AgentSupport.title(book.id)
            if let q, !AgentSupport.normalize(title + " " + (s.author ?? "")).contains(q) { return nil }
            if let st = args.string("status"), s.status.rawValue != st { return nil }
            if let c = args.string("collection"), !s.collections.contains(where: { $0.caseInsensitiveCompare(c) == .orderedSame }) { return nil }
            var row = "- \(title)" + (s.author.map { " — \($0)" } ?? "") + " (id \(book.id), \(book.format.displayName), \(s.status.rawValue), \(AgentSupport.percent(s.progress)) read"
            row += ", \(s.liveHighlights.count) highlights, \(s.liveBookmarks.count) bookmarks"
            if !s.collections.isEmpty { row += ", collections: \(s.collections.joined(separator: ", "))" }
            return row + ")"
        }
        return .text(rows.isEmpty ? "No books match." : "\(rows.count) books:\n" + rows.joined(separator: "\n"))
    }

    static let setStatus = AgentTool(
        name: "set_reading_status",
        description: "Mark a book as unread (want to read), reading or finished.",
        kind: .change, progress: "Updating the book",
        parameters: [
            .init(name: "status", type: .string, description: "New status.", required: true, options: ReadingStatus.allCases.map(\.rawValue)),
            .init(name: "book_id", type: .string, description: "A book id; defaults to the open book."),
        ]
    ) { args, session in
        let id = try AgentSupport.bookID(args, session)
        guard let status = args.string("status").flatMap(ReadingStatus.init(rawValue:)) else { throw ToolError.invalid("Unknown status.") }
        let old = AgentSupport.library.state(id).status
        AgentSupport.library.update(id) { $0.status = status; $0.statusUpdated = Date() }
        let name = status == .unread ? "Want to Read" : status.rawValue.capitalized
        let activity = AgentActivity(symbol: "checkmark.circle", title: "Marked \(AgentSupport.title(id)) as \(name)") {
            AgentSupport.library.update(id) { $0.status = old; $0.statusUpdated = Date() }
        }
        return ToolResult(text: "Done.", activity: activity)
    }

    static let setCollections = AgentTool(
        name: "set_collections",
        description: "Add a book to collections or remove it from them. New collection names are created automatically.",
        kind: .change, progress: "Organising your library",
        parameters: [
            .init(name: "add", type: .stringArray, description: "Collections to add the book to."),
            .init(name: "remove", type: .stringArray, description: "Collections to remove the book from."),
            .init(name: "book_id", type: .string, description: "A book id; defaults to the open book."),
        ]
    ) { args, session in
        let id = try AgentSupport.bookID(args, session)
        let add = args.strings("add"), remove = Set(args.strings("remove").map { $0.lowercased() })
        guard !add.isEmpty || !remove.isEmpty else { throw ToolError.invalid("Give collections to add or remove.") }
        let old = AgentSupport.library.state(id).collections
        AgentSupport.library.update(id) { s in
            s.collections.removeAll { remove.contains($0.lowercased()) }
            for c in add where !s.collections.contains(where: { $0.caseInsensitiveCompare(c) == .orderedSame }) { s.collections.append(c) }
            s.collectionsUpdated = Date()
        }
        var parts: [String] = []
        if !add.isEmpty { parts.append("added to \(add.joined(separator: ", "))") }
        if !remove.isEmpty { parts.append("removed from \(args.strings("remove").joined(separator: ", "))") }
        let activity = AgentActivity(symbol: "rectangle.stack", title: "\(AgentSupport.title(id)): \(parts.joined(separator: "; "))") {
            AgentSupport.library.update(id) { $0.collections = old; $0.collectionsUpdated = Date() }
        }
        return ToolResult(text: "Done.", activity: activity)
    }
}

// MARK: - Reading settings

@MainActor
enum SettingsTools {
    static let all: [AgentTool] = [changeSettings]

    static let changeSettings = AgentTool(
        name: "change_reading_settings",
        description: "Change how books look: theme, font, size, spacing, margins, layout and page spread. Only the given settings change.",
        kind: .change, progress: "Adjusting the page",
        parameters: [
            .init(name: "theme", type: .string, description: "Color theme.", options: ReaderTheme.allCases.map(\.rawValue)),
            .init(name: "font", type: .string, description: "Typeface.", options: ReaderFont.all.map(\.name)),
            .init(name: "font_size", type: .number, description: "Text size in points (12–40)."),
            .init(name: "line_spacing", type: .number, description: "Line height multiple (1.1–2.2)."),
            .init(name: "margins", type: .number, description: "Side margins in points (16–140)."),
            .init(name: "layout", type: .string, description: "Turn pages or scroll.", options: ["pages", "scroll"]),
            .init(name: "page_spread", type: .string, description: "One page, two pages, or automatic.", options: ["auto", "single", "double"]),
            .init(name: "justify", type: .boolean, description: "Justify paragraphs."),
            .init(name: "hyphenate", type: .boolean, description: "Hyphenate words."),
        ]
    ) { args, _ in
        let settings = ReaderSettings.shared
        let old = settings.prefs
        var p = old
        if let t = args.string("theme").flatMap(ReaderTheme.init(rawValue:)) { p.theme = t }
        if let f = args.string("font"), let font = ReaderFont.all.first(where: { $0.name.caseInsensitiveCompare(f) == .orderedSame }) { p.fontID = font.id }
        if let v = args.double("font_size") { p.fontSize = min(max(v, 12), 40) }
        if let v = args.double("line_spacing") { p.lineHeight = min(max(v, 1.1), 2.2) }
        if let v = args.double("margins") { p.margin = min(max(v, 16), 140) }
        if let v = args.string("layout") { p.layout = v == "scroll" ? .scroll : .paginated }
        if let v = args.string("page_spread").flatMap(SpreadMode.init(rawValue:)) { p.spread = v }
        if let v = args.bool("justify") { p.justify = v }
        if let v = args.bool("hyphenate") { p.hyphenate = v }
        guard p != old else { return .text("Nothing changed.") }
        settings.prefs = p
        let activity = AgentActivity(symbol: "textformat.size", title: "Changed reading settings") { ReaderSettings.shared.prefs = old }
        return ToolResult(text: "Done.", activity: activity)
    }
}
