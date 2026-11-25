import Foundation

/// How a book is rendered.
enum PublicationKind: String, Codable, Sendable {
    /// HTML spine rendered in a web view (EPUB, MOBI, AZW3, FB2, TXT, Markdown, RTF, DOCX…).
    case reflowable
    /// PDF rendered with PDFKit.
    case pdf
    /// Ordered page images (CBZ, CBR, CB7, CBT).
    case comic
}

struct SpineItem: Codable, Hashable, Sendable {
    /// Absolute file URL of an XHTML/HTML document (reflowable) or an image (comic).
    var url: URL
    /// Approximate content size used to weight whole-book progress.
    var weight: Int
    /// EPUB pre-paginated (fixed layout) document.
    var fixedLayout: Bool = false
}

struct TOCEntry: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var title: String
    /// Index into `Publication.spine` (or page index for PDF/comics).
    var spineIndex: Int
    /// Optional element id inside the spine document.
    var fragment: String?
    var children: [TOCEntry] = []
}

struct Publication: Codable, Sendable {
    var kind: PublicationKind
    var title: String
    var author: String?
    var language: String?
    var spine: [SpineItem]
    var toc: [TOCEntry]
    var coverURL: URL?
    /// Page progression right-to-left (manga, Arabic, Hebrew…).
    var rightToLeft: Bool = false
    /// Directory every spine URL lives under; the web view gets read access to it.
    var rootDirectory: URL
    /// The original file (PDF documents render straight from it).
    var sourceURL: URL

    var totalWeight: Int { max(1, spine.reduce(0) { $0 + max(1, $1.weight) }) }

    /// Whole-book progress (0…1) for a position inside the spine.
    func progress(spineIndex: Int, progression: Double) -> Double {
        progressCalculator(spineIndex: spineIndex)(progression)
    }

    /// `progress(spineIndex:progression:)` for many positions in one spine item.
    func progressCalculator(spineIndex: Int) -> (Double) -> Double {
        guard !spine.isEmpty else { return { _ in 0 } }
        let i = min(max(0, spineIndex), spine.count - 1)
        let before = Double(spine[..<i].reduce(0) { $0 + max(1, $1.weight) })
        let weight = Double(max(1, spine[i].weight))
        let total = Double(totalWeight)
        return { (before + weight * min(max($0, 0), 1)) / total }
    }

    /// Inverse of `progress(spineIndex:progression:)`.
    func position(forProgress p: Double) -> (spineIndex: Int, progression: Double) {
        guard !spine.isEmpty else { return (0, 0) }
        let target = min(max(p, 0), 1) * Double(totalWeight)
        var acc = 0.0
        for (i, item) in spine.enumerated() {
            let w = Double(max(1, item.weight))
            if acc + w >= target { return (i, (target - acc) / w) }
            acc += w
        }
        return (spine.count - 1, 1)
    }

    /// The deepest TOC entry at or before the given spine index.
    func tocEntry(forSpineIndex index: Int) -> TOCEntry? {
        var best: TOCEntry?
        func walk(_ entries: [TOCEntry]) {
            for e in entries {
                if e.spineIndex <= index, best == nil || e.spineIndex >= best!.spineIndex { best = e }
                walk(e.children)
            }
        }
        walk(toc)
        return best
    }
}

enum PublicationError: LocalizedError {
    case unsupportedFormat(String)
    case corrupt(String)
    case drmProtected

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext): "“.\(ext)” files aren’t supported."
        case .corrupt(let reason): "This book couldn’t be opened: \(reason)"
        case .drmProtected: "This book is DRM-protected. Only DRM-free books can be opened."
        }
    }
}
