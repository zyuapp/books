import AppKit
import Observation
import SwiftUI

/// The text the user selected, in the reader view's coordinate space (top-left origin).
struct ReaderSelection: Equatable {
    var text: String
    var rect: CGRect
    var range: TextRange?
    var pdfRects: [PDFRect]?
    var pageIndex: Int?
    /// Set when the selection is an existing highlight that was clicked.
    var highlightID: UUID?
}

struct FootnotePopup: Equatable {
    var text: String
    var rect: CGRect
    /// Set for notes in another chapter, so the card can jump there.
    var link: URL?
}

@MainActor
protocol ReaderEngine: AnyObject {
    func go(to locator: Locator, fragment: String?, atEnd: Bool)
    func next()
    func previous()
    func applySettings()
    func refreshHighlights()
    func reveal(_ result: SearchResult, query: String)
    func clearSelection()
    /// Plain text of the section around the current position.
    func currentSectionText() async -> String
    func currentSnippet() async -> String
    /// Plain text of what is on screen.
    func currentPageText() async -> String
    /// Zooms fixed pages in (`step > 0`) or out; 0 fits them to the window.
    func zoom(by step: Int)
    func scrollContent(by fraction: CGFloat)
    /// Finds `quote` on the current chapter or page so it can be highlighted.
    func locate(_ quote: String) async -> HighlightTarget?
    /// Waits until the current chapter or page has finished loading.
    func waitUntilContentReady() async
    /// Gives the page keyboard focus (e.g. after jumping from a panel).
    func focusContent()
    /// Character offsets of element ids in the current chapter (reflowable only).
    func fragmentOffsets(_ ids: [String]) async -> [String: Int]
}

extension ReaderEngine {
    func fragmentOffsets(_ ids: [String]) async -> [String: Int] { [:] }
    func locate(_ quote: String) async -> HighlightTarget? { nil }
    func waitUntilContentReady() async {}
    func zoom(by step: Int) {}
    func scrollContent(by fraction: CGFloat) {}
}

/// Where a quoted passage sits, in the form a `Highlight` stores.
struct HighlightTarget {
    var text: String
    var index: Int
    var progression: Double
    var range: TextRange?
    var pdfRects: [PDFRect]?
}

enum ReaderPanel: Equatable { case contents, notes, search }

/// State of one reader window.
@MainActor @Observable
final class ReaderModel {
    let book: BookRecord
    private(set) var publication: Publication?
    private(set) var loadError: String?
    private(set) var isDownloading = false

    private(set) var location: Locator
    var pageInChapter = 0
    var pagesInChapter = 1

    var panel: ReaderPanel?
    var showClaude = false
    var claudeShowsHistory = false
    var claudeExpanded = UserDefaults.standard.object(forKey: "claudeExpanded") as? Bool ?? true {
        didSet { UserDefaults.standard.set(claudeExpanded, forKey: "claudeExpanded") }
    }
    /// Bumped to move keyboard focus into Claude's input.
    var claudeFocusRequest = 0
    var claudeInputFocused = false
    var showSettings = false
    /// Controls auto-hide only in full screen; in a window they stay put.
    var chromeVisible = true
    var isFullScreen = false {
        didSet {
            guard isFullScreen != oldValue else { return }
            withAnimation(.easeInOut(duration: 0.3)) { chromeVisible = true }
            if isFullScreen { scheduleChromeHide() } else { chromeTask?.cancel() }
        }
    }
    var selection: ReaderSelection?
    var footnote: FootnotePopup?
    var noteEditor: Highlight?
    var claudeDraft: ClaudeRequestSeed?
    /// Set to start a blank conversation once the Claude panel handles it.
    var claudeNewThreadRequested = false

    var searchQuery = ""
    private(set) var searchResults: [SearchResult] = []
    private(set) var isSearching = false

    /// Jump history for “Back to …” (⌘Z / ⌘[) and forward (⇧⌘Z / ⌘]).
    private(set) var backStack: [Locator] = []
    private(set) var forwardStack: [Locator] = []
    var showBackPill = false

    @ObservationIgnored weak var engine: ReaderEngine?
    /// PDF zoom in percent, nil while pages fit the window.
    var zoomPercent: Int?
    /// Window-space frames (top-left origin) of floating controls; reader NSViews ignore clicks there.
    @ObservationIgnored var overlayRects: [CGRect] = []
    @ObservationIgnored private var pillTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var chromeTask: Task<Void, Never>?
    @ObservationIgnored private var bookTextTask: Task<[String], Never>?
    @ObservationIgnored private var loweredBookTextTask: Task<[String], Never>?
    /// False until the reader leaves the restored spot, so restore reports never overwrite newer synced positions.
    @ObservationIgnored private var userMoved = false

    let library = LibraryStore.shared
    let settings = ReaderSettings.shared

    init(book: BookRecord) {
        self.book = book
        location = LibraryStore.shared.state(book.id).position ?? Locator(index: 0)
    }

    var state: ReadingState { library.state(book.id) }
    var title: String { publication?.title ?? state.title ?? book.url.deletingPathExtension().lastPathComponent }

    var chapterTitle: String? {
        guard let publication else { return nil }
        if publication.kind == .pdf || publication.kind == .comic {
            return publication.tocEntry(forSpineIndex: location.index)?.title
        }
        return publication.tocEntry(forSpineIndex: location.index)?.title
    }

    var isBookmarked: Bool { currentBookmark != nil }

    private var currentBookmark: Bookmark? {
        state.liveBookmarks.first { bm in
            guard bm.locator.index == location.index else { return false }
            if publication?.kind != .reflowable { return true }
            return abs(bm.locator.progression - location.progression) < 0.5 / Double(max(1, pagesInChapter))
        }
    }

    // MARK: Loading

    func load() async {
        guard publication == nil else { return }
        do {
            if !book.isDownloaded {
                isDownloading = true
                try await library.ensureDownloaded(book)
                isDownloading = false
            }
            await library.waitUntilReady()
            location = library.state(book.id).position ?? Locator(index: 0)
            let url = book.url, id = book.id
            let pub = try await Task.detached(priority: .userInitiated) { try BookLoader.load(url, bookID: id) }.value
            publication = pub
            if location.index >= pub.spine.count { location = Locator(index: 0) }
            library.update(book.id) { s in
                s.lastOpened = Date()
                s.title = s.title ?? pub.title
                s.author = s.author ?? pub.author
                if s.status == .unread { s.status = .reading; s.statusUpdated = Date() }
            }
        } catch {
            isDownloading = false
            loadError = error.localizedDescription
        }
    }

    // MARK: Position

    /// Called by engines whenever the visible position changes.
    func engineDidMove(to locator: Locator, page: Int, pageCount: Int, atEnd engineAtEnd: Bool) {
        var l = locator
        if let publication {
            l.totalProgress = publication.progress(spineIndex: l.index, progression: l.progression)
            if publication.kind == .reflowable {
                l.label = publication.tocEntry(forSpineIndex: l.index)?.title
            } else {
                l.label = "Page \(l.index + 1)"
            }
        }
        let restored = location
        location = l
        pageInChapter = page
        pagesInChapter = pageCount
        if !userMoved {
            let samePlace = restored.index == l.index && abs(restored.progression - l.progression) < 0.02
            if samePlace { return }
            userMoved = true
        }
        let atEnd = engineAtEnd && l.index >= (publication?.spine.count ?? 1) - 1
        library.update(book.id) { s in
            s.position = l
            s.positionUpdated = Date()
            if atEnd && s.status != .finished {
                s.status = .finished
                s.statusUpdated = Date()
            }
        }
    }

    func restoreTarget() -> Locator { location }

    // MARK: Navigation

    func nextPage() { userMoved = true; selection = nil; footnote = nil; engine?.next() }
    func previousPage() { userMoved = true; selection = nil; footnote = nil; engine?.previous() }
    /// Moves a zoomed-in page by `fraction` of the visible height (negative is up); never turns the page.
    func scrollContent(by fraction: CGFloat) { engine?.scrollContent(by: fraction) }

    /// A deliberate jump (TOC, link, search, scrubber…). Recorded so it can be undone.
    func jump(to locator: Locator, fragment: String? = nil) {
        recordJump()
        selection = nil
        footnote = nil
        engine?.go(to: locator, fragment: fragment, atEnd: false)
        engine?.focusContent()
    }

    func jump(toProgress p: Double) {
        guard let publication else { return }
        let pos = publication.position(forProgress: p)
        if publication.kind == .reflowable {
            jump(to: Locator(index: pos.spineIndex, progression: pos.progression))
        } else {
            jump(to: Locator(index: Int((p * Double(publication.spine.count - 1)).rounded())))
        }
    }

    /// Records the current spot before a scrubber drag; the drag itself moves without recording.
    func beginScrub() { recordJump() }

    func scrub(toProgress p: Double) {
        guard let publication else { return }
        let pos = publication.position(forProgress: p)
        if publication.kind == .reflowable {
            engine?.go(to: Locator(index: pos.spineIndex, progression: pos.progression), fragment: nil, atEnd: false)
        } else {
            engine?.go(to: Locator(index: Int((p * Double(publication.spine.count - 1)).rounded())), fragment: nil, atEnd: false)
        }
    }

    func go(to entry: TOCEntry) {
        jump(to: Locator(index: entry.spineIndex), fragment: entry.fragment)
    }

    func openLink(_ url: URL) {
        guard let publication else { return }
        let path = url.standardizedFileURL.path
        guard let index = publication.spine.firstIndex(where: { $0.url.standardizedFileURL.path == path }) else { return }
        let fragment = url.fragment.flatMap { $0.removingPercentEncoding ?? $0 }
        jump(to: Locator(index: index), fragment: fragment)
    }

    private func recordJump() {
        userMoved = true
        if backStack.last != location { backStack.append(location) }
        if backStack.count > 50 { backStack.removeFirst() }
        forwardStack.removeAll()
        flashBackPill()
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var backLabel: String {
        guard let l = backStack.last else { return "" }
        return Self.describe(l, publication: publication)
    }

    func goBack() {
        guard let target = backStack.popLast() else { return }
        userMoved = true
        defer { engine?.focusContent() }
        forwardStack.append(location)
        engine?.go(to: target, fragment: nil, atEnd: false)
        if backStack.isEmpty { showBackPill = false } else { flashBackPill() }
    }

    func goForward() {
        guard let target = forwardStack.popLast() else { return }
        userMoved = true
        backStack.append(location)
        engine?.go(to: target, fragment: nil, atEnd: false)
        flashBackPill()
    }

    private func flashBackPill() {
        withAnimation(.spring(duration: 0.35)) { showBackPill = true }
        pillTask?.cancel()
        pillTask = Task {
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { showBackPill = false }
        }
    }

    static func describe(_ l: Locator, publication: Publication?) -> String {
        let pct = Int((l.totalProgress * 100).rounded())
        if publication?.kind == .pdf || publication?.kind == .comic { return "Page \(l.index + 1)" }
        if let label = l.label ?? publication?.tocEntry(forSpineIndex: l.index)?.title {
            return "\(label) · \(pct)%"
        }
        return "\(pct)%"
    }

    // MARK: Chrome

    @ObservationIgnored private var chromeHiddenByTap = Date.distantPast

    func pokeChrome() {
        guard Date().timeIntervalSince(chromeHiddenByTap) > 0.8 else { return }
        if !chromeVisible { withAnimation(.easeOut(duration: 0.25)) { chromeVisible = true } }
        scheduleChromeHide()
    }

    /// Closes the side panel; returns false when none was open.
    func dismissPanel() -> Bool {
        guard panel != nil else { return false }
        panel = nil
        return true
    }

    func toggleChrome() {
        guard isFullScreen else { return }
        if chromeVisible {
            chromeTask?.cancel()
            chromeHiddenByTap = Date()
            withAnimation(.easeInOut(duration: 0.3)) { chromeVisible = false }
        } else {
            pokeChrome()
        }
    }

    func scheduleChromeHide() {
        chromeTask?.cancel()
        guard isFullScreen else { return }
        chromeTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, isFullScreen, panel == nil, !showClaude, !showSettings, selection == nil else { return }
            withAnimation(.easeInOut(duration: 0.45)) { chromeVisible = false }
        }
    }

    // MARK: Paging traits

    var pagesRightToLeft: Bool {
        guard let publication else { return false }
        if publication.kind == .comic { return settings.prefs.comicRightToLeft ?? publication.rightToLeft }
        return publication.rightToLeft
    }

    var isPaginatedLayout: Bool {
        publication?.kind == .comic || settings.prefs.layout == .paginated
    }

    /// ⌥→ next TOC entry; ⌥← start of the current entry, or the previous one when already at its start.
    func goToChapter(offset: Int) {
        guard let publication else { return }
        let entries = Self.flatten(publication.toc)
        guard !entries.isEmpty else { return }
        let current = location.index
        let here = location.textOffset ?? 0
        Task {
            let ids = entries.filter { $0.spineIndex == current }.compactMap(\.fragment)
            let offsets = ids.isEmpty ? [:] : (await engine?.fragmentOffsets(ids) ?? [:])
            // Signed distance of an entry from the reading position (TOC order breaks ties across chapters).
            func compare(_ e: TOCEntry) -> Int {
                if e.spineIndex != current { return e.spineIndex < current ? -1 : 1 }
                let pos = e.fragment.flatMap { offsets[$0] } ?? 0
                if pos > here + 40 { return 1 }
                if pos < here - 40 { return -1 }
                return 0
            }
            let target = offset > 0
                ? entries.first { compare($0) > 0 }
                : entries.last { compare($0) < 0 }
            guard let target else { return }
            go(to: target)
        }
    }

    func goToStart() { jump(to: Locator(index: 0)) }

    func goToEnd() {
        guard let publication else { return }
        recordJumpForKeys()
        engine?.go(to: Locator(index: publication.spine.count - 1, progression: 1), fragment: nil, atEnd: true)
    }

    private func recordJumpForKeys() { recordJump(); selection = nil; footnote = nil }

    static func flatten(_ entries: [TOCEntry]) -> [TOCEntry] {
        entries.flatMap { [$0] + flatten($0.children) }
    }

    /// Esc: dismiss the innermost thing first, then leave full screen, then return to the library.
    func handleEscape(window: NSWindow?) {
        if selection != nil || footnote != nil {
            selection = nil
            footnote = nil
            engine?.clearSelection()
        } else if showSettings {
            showSettings = false
        } else if showClaude && claudeShowsHistory {
            withAnimation(.smooth(duration: 0.3)) { claudeShowsHistory = false }
        } else if showClaude || panel != nil {
            withAnimation(.spring(duration: 0.35)) { showClaude = false; panel = nil }
        } else if let window, window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        } else {
            OpenBridge.shared.showLibrary()
        }
    }

    // MARK: Bookmarks & highlights

    func toggleBookmark() {
        if let bm = currentBookmark {
            library.update(book.id) { s in
                if let i = s.bookmarks.firstIndex(where: { $0.id == bm.id }) {
                    s.bookmarks[i].deleted = true
                    s.bookmarks[i].updated = Date()
                }
            }
            return
        }
        let locator = location
        Task {
            let snippet = await engine?.currentSnippet() ?? ""
            library.update(book.id) { s in
                s.bookmarks.append(Bookmark(locator: locator, snippet: snippet.isEmpty ? Self.describe(locator, publication: publication) : snippet))
            }
        }
    }

    func highlightSelection(_ color: HighlightColor) {
        guard let sel = selection else { return }
        if let id = sel.highlightID {
            updateHighlight(id) { $0.color = color }
        } else {
            var l = location
            if let page = sel.pageIndex { l = Locator(index: page, totalProgress: publication?.progress(spineIndex: page, progression: 0) ?? 0) }
            addHighlight(Highlight(locator: l, text: sel.text, color: color, range: sel.range, pdfRects: sel.pdfRects))
        }
        selection = nil
        engine?.clearSelection()
        engine?.refreshHighlights()
    }

    func addNoteToSelection() {
        guard let sel = selection else { return }
        if let id = sel.highlightID, let h = state.liveHighlights.first(where: { $0.id == id }) {
            noteEditor = h
        } else {
            var l = location
            if let page = sel.pageIndex { l = Locator(index: page) }
            let h = Highlight(locator: l, text: sel.text, color: .yellow, range: sel.range, pdfRects: sel.pdfRects)
            library.update(book.id) { $0.highlights.append(h) }
            engine?.refreshHighlights()
            noteEditor = h
        }
        selection = nil
        engine?.clearSelection()
    }

    /// Highlights, notes and bookmarks in reading order, as Markdown.
    func notesMarkdown() -> String {
        let highlights = state.liveHighlights.sorted { ($0.locator.totalProgress, $0.range?.start ?? 0) < ($1.locator.totalProgress, $1.range?.start ?? 0) }
        let bookmarks = state.liveBookmarks.sorted { $0.locator.totalProgress < $1.locator.totalProgress }
        var md = "# \(title)\n"
        if let a = publication?.author { md += "*\(a)*\n" }
        for h in highlights {
            md += "\n> \(h.text.replacingOccurrences(of: "\n", with: "\n> "))\n"
            if let n = h.note { md += "\n\(n)\n" }
            md += "\n— \(Self.describe(h.locator, publication: publication))\n"
        }
        if !bookmarks.isEmpty {
            md += "\n## Bookmarks\n"
            for b in bookmarks { md += "- \(b.snippet) (\(Self.describe(b.locator, publication: publication)))\n" }
        }
        return md
    }

    func addHighlight(_ h: Highlight) {
        library.update(book.id) { $0.highlights.append(h) }
        engine?.refreshHighlights()
    }

    func addBookmark(_ b: Bookmark) {
        library.update(book.id) { $0.bookmarks.append(b) }
    }

    func setBookmarkDeleted(_ id: UUID, _ deleted: Bool) {
        library.update(book.id) { s in
            guard let i = s.bookmarks.firstIndex(where: { $0.id == id }) else { return }
            s.bookmarks[i].deleted = deleted
            s.bookmarks[i].updated = Date()
        }
    }

    func updateHighlight(_ id: UUID, _ change: (inout Highlight) -> Void) {
        library.update(book.id) { s in
            guard let i = s.highlights.firstIndex(where: { $0.id == id }) else { return }
            change(&s.highlights[i])
            s.highlights[i].updated = Date()
        }
        engine?.refreshHighlights()
    }

    func deleteHighlight(_ id: UUID) {
        updateHighlight(id) { $0.deleted = true }
        selection = nil
    }

    func deleteBookmark(_ id: UUID) { setBookmarkDeleted(id, true) }

    func copySelection() {
        guard let sel = selection else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sel.text, forType: .string)
        selection = nil
        engine?.clearSelection()
    }

    // MARK: Claude

    func askClaude(action: ClaudeQuickAction?) {
        let passage = selection?.text
        // Opening the panel on its own resumes the current conversation.
        if passage != nil || action != nil {
            claudeDraft = ClaudeRequestSeed(passage: passage, action: action, locator: location)
        }
        selection = nil
        engine?.clearSelection()
        withAnimation(.spring(duration: 0.4)) { showClaude = true }
        claudeFocusRequest += 1
    }

    func newClaudeChat() {
        claudeDraft = nil
        claudeNewThreadRequested = true
        selection = nil
        engine?.clearSelection()
        withAnimation(.spring(duration: 0.4)) { showClaude = true }
        claudeFocusRequest += 1
    }

    /// Plain text of every spine item (pages for PDFs), cached.
    func bookTexts() async -> [String] {
        if let bookTextTask { return await bookTextTask.value }
        guard let publication else { return [] }
        let pub = publication
        let id = book.id
        let task = Task.detached(priority: .userInitiated) { TextExtractor.texts(for: pub, bookID: id) }
        bookTextTask = task
        return await task.value
    }

    private func loweredBookTexts(_ texts: [String]) async -> [String] {
        if let loweredBookTextTask { return await loweredBookTextTask.value }
        let task = Task.detached(priority: .userInitiated) { TextExtractor.lowercased(texts) }
        loweredBookTextTask = task
        return await task.value
    }

    // MARK: Search

    func search(_ query: String) {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2, let publication else { searchResults = []; isSearching = false; return }
        isSearching = true
        let pub = publication
        searchTask = Task {
            let texts = await bookTexts()
            guard !Task.isCancelled else { return }
            let lowered = await loweredBookTexts(texts)
            guard !Task.isCancelled else { return }
            let results = await Task.detached(priority: .userInitiated) {
                TextExtractor.search(q, in: texts, lowered: lowered, publication: pub)
            }.value
            guard !Task.isCancelled else { return }
            searchResults = results
            isSearching = false
        }
    }

    func reveal(_ result: SearchResult) {
        recordJump()
        engine?.reveal(result, query: searchQuery.trimmingCharacters(in: .whitespacesAndNewlines))
        engine?.focusContent()
    }
}

struct ClaudeRequestSeed: Equatable, Identifiable {
    let id = UUID()
    var passage: String?
    var action: ClaudeQuickAction?
    var locator: Locator
}

enum ClaudeQuickAction: String, CaseIterable, Identifiable {
    case explain, summarize, define, discuss

    var id: String { rawValue }

    var title: String {
        switch self {
        case .explain: "Explain"
        case .summarize: "Summarize"
        case .define: "Define"
        case .discuss: "Discuss"
        }
    }

    var symbol: String {
        switch self {
        case .explain: "lightbulb"
        case .summarize: "text.append"
        case .define: "character.book.closed"
        case .discuss: "bubble.left.and.text.bubble.right"
        }
    }

    func subtitle(hasPassage: Bool) -> String {
        switch self {
        case .explain: hasPassage ? "What it means and why it matters" : "What’s happening right now"
        case .summarize: hasPassage ? "The passage in a few sentences" : "Catch up on this chapter"
        case .define: "Key words, as used here"
        case .discuss: "Themes, techniques and references"
        }
    }

    func prompt(hasPassage: Bool) -> String {
        switch self {
        case .explain: hasPassage ? "Explain this passage — what it means, and why it matters in context." : "Explain what is happening at this point in the book."
        case .summarize: hasPassage ? "Summarize this passage in a few sentences." : "Summarize this chapter so far."
        case .define: "Define the key word or phrase in this selection as it is used here, with a short etymology if interesting."
        case .discuss: "What themes, techniques or references are at work here? Give me something interesting to think about."
        }
    }
}

/// Reader keyboard shortcuts, handled for the whole window so they work without clicking the page first.
@MainActor
enum ReaderKeys {
    static func handle(_ event: NSEvent, model: ReaderModel, window: NSWindow) -> Bool {
        if window.attachedSheet != nil { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad, .capsLock])
        if event.keyCode == 13, mods == .command {   // ⌘W, layout independent
            OpenBridge.shared.showLibrary()
            return true
        }
        if event.keyCode == 53, mods.isEmpty, !((window.firstResponder as? NSTextView)?.hasMarkedText() ?? false) {
            model.handleEscape(window: window)
            if window.firstResponder is NSText { window.makeFirstResponder(nil) }
            return true
        }
        // Leave typing alone.
        if let responder = window.firstResponder as? NSText, responder.isEditable { return false }
        if window.firstResponder is NSTextField { return false }
        // Full Keyboard Access: a focused control keeps its own arrows and space.
        if let control = window.firstResponder as? NSControl, !(control is NSScrollView) { return false }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad, .capsLock])
        let rtl = model.pagesRightToLeft
        let forward = { model.nextPage() }
        let back = { model.previousPage() }
        let paged = model.isPaginatedLayout

        switch (Int(event.keyCode), flags) {
        case (123, []): rtl ? forward() : back()                 // ←
        case (124, []): rtl ? back() : forward()                 // →
        // In paged layouts only ← and → turn pages; the rest move around a zoomed-in page.
        case (125, []) where paged: model.scrollContent(by: 0.12)    // ↓
        case (126, []) where paged: model.scrollContent(by: -0.12)   // ↑
        case (121, []), (49, []): paged ? model.scrollContent(by: 0.9) : forward()     // page down, space
        case (116, []), (49, .shift): paged ? model.scrollContent(by: -0.9) : back()   // page up, ⇧space
        case (115, []): model.goToStart()                        // home
        case (119, []): model.goToEnd()                          // end
        case (123, .option): model.goToChapter(offset: rtl ? 1 : -1)
        case (124, .option): model.goToChapter(offset: rtl ? -1 : 1)
        default:
            if event.keyCode == 6, flags == .command, model.canGoBack { model.goBack(); return true }
            if event.keyCode == 6, flags == [.command, .shift], model.canGoForward { model.goForward(); return true }
            return false
        }
        return true
    }
}

struct OverlayFramesKey: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

extension View {
    /// Marks this view as a floating control that must receive clicks over the page.
    func readerOverlay() -> some View {
        background(GeometryReader { geo in
            Color.clear.preference(key: OverlayFramesKey.self, value: [geo.frame(in: .global)])
        })
    }
}

extension NSView {
    /// True when a point (in the superview's coordinates) lies under a floating SwiftUI control.
    func isUnderOverlay(_ point: NSPoint, rects: [CGRect]) -> Bool {
        guard let superview, let content = window?.contentView, !rects.isEmpty else { return false }
        let p = superview.convert(point, to: nil)
        let top = CGPoint(x: p.x, y: content.bounds.height - p.y)
        return rects.contains { $0.insetBy(dx: -2, dy: -2).contains(top) }
    }
}
