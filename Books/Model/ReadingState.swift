import Foundation

/// A position in a book. `index` is the spine item (reflowable), page (PDF) or image (comic).
struct Locator: Codable, Hashable, Sendable {
    var index: Int
    var progression: Double = 0
    /// Whole-book progress, 0…1.
    var totalProgress: Double = 0
    /// Human-readable label, e.g. chapter title or “Page 12”.
    var label: String?
    /// Character offset of the first visible text in the chapter (reflowable only); survives relayout.
    var textOffset: Int?
}

enum HighlightColor: String, Codable, CaseIterable, Sendable {
    case yellow, green, blue, pink, purple, underline
}

/// Reflowable highlight anchor: character offsets into the chapter's `body.textContent`.
struct TextRange: Codable, Hashable, Sendable {
    var start: Int
    var end: Int
}

struct PDFRect: Codable, Hashable, Sendable {
    var x: Double, y: Double, width: Double, height: Double
}

protocol Syncable: Identifiable, Codable where ID == UUID {
    var id: UUID { get }
    var updated: Date { get }
    var deleted: Bool { get }
}

struct Highlight: Syncable, Hashable, Sendable {
    var id = UUID()
    var locator: Locator
    var text: String
    var note: String?
    var color: HighlightColor = .yellow
    var range: TextRange?
    var pdfRects: [PDFRect]?
    var created = Date()
    var updated = Date()
    var deleted = false
}

struct Bookmark: Syncable, Hashable, Sendable {
    var id = UUID()
    var locator: Locator
    var snippet: String
    var created = Date()
    var updated = Date()
    var deleted = false
}

struct ChatMessage: Codable, Hashable, Identifiable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant }
    var id = UUID()
    var role: Role
    var text: String
    var date = Date()
    /// What Claude did in the app while writing this answer.
    var actions: [String]? = nil
}

struct ChatThread: Syncable, Hashable, Sendable {
    var id = UUID()
    var title: String
    var passage: String?
    var locator: Locator?
    /// Never `.page`, so older versions syncing this thread can still decode it; see `pageOnly`.
    var scope: ClaudeScope = .chapter
    var pageOnly: Bool?
    var messages: [ChatMessage] = []
    var created = Date()
    var updated = Date()
    var deleted = false

    var contextScope: ClaudeScope {
        get { pageOnly == true ? .page : scope }
        set {
            scope = newValue == .page ? .chapter : newValue
            pageOnly = newValue == .page ? true : nil
        }
    }
}

/// Context older versions let the reader pick; kept so synced threads still decode.
enum ClaudeScope: String, Codable, CaseIterable, Sendable {
    case passage, page, chapter, book
}

enum ReadingStatus: String, Codable, CaseIterable, Sendable {
    case unread, reading, finished
}

/// Everything about one book that syncs through iCloud Drive (`Reading Data/<id>.json`).
struct ReadingState: Codable, Sendable {
    var bookID: String
    var fileName: String
    var title: String?
    var author: String?
    var format: BookFormat?

    var position: Locator?
    var positionUpdated = Date.distantPast
    var status: ReadingStatus = .unread
    var statusUpdated = Date.distantPast
    var collections: [String] = []
    var collectionsUpdated = Date.distantPast
    var lastOpened: Date?
    var added = Date()

    var highlights: [Highlight] = []
    var bookmarks: [Bookmark] = []
    var chats: [ChatThread] = []

    init(bookID: String, fileName: String) {
        self.bookID = bookID
        self.fileName = fileName
    }

    var progress: Double { position?.totalProgress ?? 0 }
    var liveHighlights: [Highlight] { highlights.filter { !$0.deleted } }
    var liveBookmarks: [Bookmark] { bookmarks.filter { !$0.deleted } }
    var liveChats: [ChatThread] { chats.filter { !$0.deleted }.sorted { $0.updated > $1.updated } }

    /// Field-level last-writer-wins merge, so edits from two Macs never clobber each other.
    func merged(with other: ReadingState) -> ReadingState {
        var m = self
        if other.positionUpdated > positionUpdated {
            m.position = other.position
            m.positionUpdated = other.positionUpdated
        }
        if other.statusUpdated > statusUpdated {
            m.status = other.status
            m.statusUpdated = other.statusUpdated
        }
        if other.collectionsUpdated > collectionsUpdated {
            m.collections = other.collections
            m.collectionsUpdated = other.collectionsUpdated
        }
        m.lastOpened = [lastOpened, other.lastOpened].compactMap { $0 }.max()
        m.added = min(added, other.added)
        m.title = title ?? other.title
        m.author = author ?? other.author
        m.format = format ?? other.format
        m.highlights = Self.merge(highlights, other.highlights)
        m.bookmarks = Self.merge(bookmarks, other.bookmarks)
        m.chats = Self.merge(chats, other.chats)
        return m
    }

    private static func merge<T: Syncable>(_ a: [T], _ b: [T]) -> [T] {
        var byID: [UUID: T] = [:]
        for item in a + b {
            if let existing = byID[item.id], existing.updated >= item.updated { continue }
            byID[item.id] = item
        }
        return byID.values.sorted { $0.updated < $1.updated }
    }
}
