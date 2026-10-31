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

struct SearchResult: Identifiable, Hashable {
    let id = UUID()
    var locator: Locator
    var occurrence: Int
    var snippet: AttributedString
    var chapter: String
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
    var showSettings = false
    var chromeVisible = true
    var selection: ReaderSelection?
    var footnote: FootnotePopup?
    var noteEditor: Highlight?
    var claudeDraft: ClaudeRequestSeed?

    var searchQuery = ""
    private(set) var searchResults: [SearchResult] = []
    private(set) var isSearching = false

    /// Jump history for “Back to …” (⌘Z / ⌘[) and forward (⇧⌘Z / ⌘]).
    private(set) var backStack: [Locator] = []
    private(set) var forwardStack: [Locator] = []
    var showBackPill = false

    @ObservationIgnored weak var engine: ReaderEngine?
    /// Window-space frames (top-left origin) of floating controls; reader NSViews ignore clicks there.
    @ObservationIgnored var overlayRects: [CGRect] = []
    @ObservationIgnored private var pillTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var chromeTask: Task<Void, Never>?
    @ObservationIgnored private var bookText: [String]?
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

    /// A deliberate jump (TOC, link, search, scrubber…). Recorded so it can be undone.
    func jump(to locator: Locator, fragment: String? = nil) {
        recordJump()
        selection = nil
        footnote = nil
        engine?.go(to: locator, fragment: fragment, atEnd: false)
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

    func pokeChrome() {
        if !chromeVisible { withAnimation(.easeOut(duration: 0.25)) { chromeVisible = true } }
        scheduleChromeHide()
    }

    func toggleChrome() {
        if chromeVisible {
            chromeTask?.cancel()
            withAnimation(.easeInOut(duration: 0.3)) { chromeVisible = false }
        } else {
            pokeChrome()
        }
    }

    func scheduleChromeHide() {
        chromeTask?.cancel()
        chromeTask = Task {
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled, panel == nil, !showClaude, !showSettings, selection == nil else { return }
            withAnimation(.easeInOut(duration: 0.45)) { chromeVisible = false }
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
            let h = Highlight(locator: l, text: sel.text, color: color, range: sel.range, pdfRects: sel.pdfRects)
            library.update(book.id) { $0.highlights.append(h) }
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

    func deleteBookmark(_ id: UUID) {
        library.update(book.id) { s in
            guard let i = s.bookmarks.firstIndex(where: { $0.id == id }) else { return }
            s.bookmarks[i].deleted = true
            s.bookmarks[i].updated = Date()
        }
    }

    func copySelection() {
        guard let sel = selection else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sel.text, forType: .string)
        selection = nil
        engine?.clearSelection()
    }

    func lookUpSelection(in view: NSView?) {
        guard let sel = selection, let view else { return }
        let point = NSPoint(x: sel.rect.minX, y: view.isFlipped ? sel.rect.maxY : view.bounds.height - sel.rect.maxY)
        view.showDefinition(for: NSAttributedString(string: sel.text), at: point)
    }

    // MARK: Claude

    func askClaude(action: ClaudeQuickAction?) {
        let passage = selection?.text
        claudeDraft = ClaudeRequestSeed(passage: passage, action: action, locator: location)
        selection = nil
        engine?.clearSelection()
        withAnimation(.spring(duration: 0.4)) { showClaude = true }
    }

    func context(for scope: ClaudeScope) async -> String {
        switch scope {
        case .passage: return ""
        case .chapter: return await engine?.currentSectionText() ?? ""
        case .book: return await fullText()
        }
    }

    private func fullText() async -> String {
        if let bookText { return bookText.joined(separator: "\n\n") }
        guard let publication else { return "" }
        let pub = publication
        let texts = await Task.detached(priority: .userInitiated) { TextExtractor.texts(for: pub) }.value
        bookText = texts
        return texts.joined(separator: "\n\n")
    }

    // MARK: Search

    func search(_ query: String) {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2, let publication else { searchResults = []; isSearching = false; return }
        isSearching = true
        let pub = publication
        let cached = bookText
        searchTask = Task {
            let texts: [String]
            if let cached { texts = cached } else {
                texts = await Task.detached(priority: .userInitiated) { TextExtractor.texts(for: pub) }.value
                bookText = texts
            }
            guard !Task.isCancelled else { return }
            let results = await Task.detached(priority: .userInitiated) {
                TextExtractor.search(q, in: texts, publication: pub)
            }.value
            guard !Task.isCancelled else { return }
            searchResults = results
            isSearching = false
        }
    }

    func reveal(_ result: SearchResult) {
        recordJump()
        engine?.reveal(result, query: searchQuery.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

struct ClaudeRequestSeed: Equatable, Identifiable {
    let id = UUID()
    var passage: String?
    var action: ClaudeQuickAction?
    var locator: Locator
}

enum ClaudeQuickAction: String, CaseIterable, Identifiable {
    case explain, summarize, define, translate, discuss

    var id: String { rawValue }

    var title: String {
        switch self {
        case .explain: "Explain"
        case .summarize: "Summarize"
        case .define: "Define"
        case .translate: "Translate"
        case .discuss: "Discuss"
        }
    }

    var symbol: String {
        switch self {
        case .explain: "lightbulb"
        case .summarize: "text.append"
        case .define: "character.book.closed"
        case .translate: "translate"
        case .discuss: "bubble.left.and.text.bubble.right"
        }
    }

    func prompt(hasPassage: Bool) -> String {
        switch self {
        case .explain: hasPassage ? "Explain this passage — what it means, and why it matters in context." : "Explain what is happening at this point in the book."
        case .summarize: hasPassage ? "Summarize this passage in a few sentences." : "Summarize this chapter so far."
        case .define: "Define the key word or phrase in this selection as it is used here, with a short etymology if interesting."
        case .translate: "Translate this passage into English (or, if it is already English, into plain modern English), preserving its tone."
        case .discuss: "What themes, techniques or references are at work here? Give me something interesting to think about."
        }
    }
}

/// ⌘Z / ⇧⌘Z undo and redo jumps while the page has focus.
@MainActor
enum JumpKeys {
    static func handle(_ event: NSEvent, model: ReaderModel) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard event.charactersIgnoringModifiers?.lowercased() == "z" else { return false }
        if flags == .command, model.canGoBack { model.goBack(); return true }
        if flags == [.command, .shift], model.canGoForward { model.goForward(); return true }
        return false
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
