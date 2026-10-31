import Foundation
import PDFKit

enum BookFormat: String, CaseIterable, Codable, Sendable {
    case epub, pdf, mobi, azw3, fb2, cbz, cbr, cb7, cbt, txt, markdown, rtf, docx, odt, html

    init?(url: URL) {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".fb2.zip") { self = .fb2; return }
        switch url.lowercaseExtension {
        case "epub", "kepub": self = .epub
        case "pdf": self = .pdf
        case "mobi", "prc": self = .mobi
        case "azw3", "azw", "kf8": self = .azw3
        case "fb2", "fbz": self = .fb2
        case "cbz": self = .cbz
        case "cbr": self = .cbr
        case "cb7": self = .cb7
        case "cbt": self = .cbt
        case "txt", "text": self = .txt
        case "md", "markdown": self = .markdown
        case "rtf", "rtfd": self = .rtf
        case "docx", "doc": self = .docx
        case "odt": self = .odt
        case "html", "htm", "xhtml": self = .html
        default: return nil
        }
    }

    static let fileExtensions = [
        "epub", "kepub", "pdf", "mobi", "prc", "azw3", "azw", "kf8", "fb2", "fbz", "cbz", "cbr", "cb7", "cbt",
        "txt", "md", "markdown", "rtf", "rtfd", "docx", "doc", "odt", "html", "htm", "xhtml",
    ]

    var displayName: String {
        switch self {
        case .epub: "EPUB"
        case .pdf: "PDF"
        case .mobi: "MOBI"
        case .azw3: "AZW3"
        case .fb2: "FB2"
        case .cbz, .cbr, .cb7, .cbt: "Comic"
        case .txt: "Text"
        case .markdown: "Markdown"
        case .rtf: "RTF"
        case .docx: "Word"
        case .odt: "OpenDocument"
        case .html: "HTML"
        }
    }

    var isComic: Bool { [.cbz, .cbr, .cb7, .cbt].contains(self) }
}

/// Parses a book file into a `Publication`, caching the unpacked result per book.
enum BookLoader {
    private static let cacheVersion = 5

    static var cacheRoot: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("com.zyuapp.books/Publications", isDirectory: true)
    }

    static func load(_ url: URL, bookID: String) throws -> Publication {
        guard let format = BookFormat(url: url) else { throw PublicationError.unsupportedFormat(url.pathExtension) }
        let fm = FileManager.default
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? 0
        let dir = cacheRoot.appendingPathComponent("\(bookID)-\(Int(mtime))-v\(cacheVersion)", isDirectory: true)
        let manifest = dir.appendingPathComponent("publication.json")

        if let data = try? Data(contentsOf: manifest),
           var cached = try? JSONDecoder().decode(Publication.self, from: data) {
            cached.sourceURL = url
            return cached
        }

        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let publication: Publication
        do {
            publication = try parse(url, format: format, into: dir)
        } catch {
            try? fm.removeItem(at: dir)
            throw error
        }
        if let data = try? JSONEncoder().encode(publication) { try? data.write(to: manifest) }
        return publication
    }

    private static func parse(_ url: URL, format: BookFormat, into dir: URL) throws -> Publication {
        switch format {
        case .epub: return try EPUBParser.parse(url, into: dir)
        case .mobi, .azw3: return try MOBIParser.parse(url, into: dir)
        case .fb2: return try FB2Parser.parse(url, into: dir)
        case .cbz, .cbr, .cb7, .cbt: return try ComicParser.parse(url, into: dir)
        case .txt: return try TextParser.parsePlainText(url, into: dir)
        case .markdown: return try TextParser.parseMarkdown(url, into: dir)
        case .rtf, .docx, .odt, .html: return try RichTextParser.parse(url, into: dir)
        case .pdf: return try PDFMetadata.publication(url)
        }
    }

    static func purgeStaleCaches(keeping ids: Set<String>) {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil) else { return }
        for dir in dirs {
            let name = dir.lastPathComponent
            let id = name.split(separator: "-").first.map(String.init) ?? ""
            if !ids.contains(id) || !name.hasSuffix("-v\(cacheVersion)") { try? fm.removeItem(at: dir) }
        }
    }
}

enum ComicParser {
    static let imageExtensions: Set = ["jpg", "jpeg", "png", "gif", "webp", "avif", "heic", "heif", "bmp", "tif", "tiff", "jxl"]

    static func parse(_ url: URL, into dir: URL) throws -> Publication {
        let root = dir.appendingPathComponent("pages", isDirectory: true)
        try Archive.extract(url, to: root)
        let files = Archive.files(in: root)
        let images = files.filter { imageExtensions.contains($0.lowercaseExtension) }
        guard !images.isEmpty else { throw PublicationError.corrupt("no images in the comic archive") }

        var title = url.deletingPathExtension().lastPathComponent
        var author: String?
        var rtl = false
        if let info = files.first(where: { $0.lastPathComponent.lowercased() == "comicinfo.xml" }),
           let doc = try? XMLDocument(contentsOf: info, options: [.nodeLoadExternalEntitiesNever]),
           let rootEl = doc.rootElement() {
            func value(_ name: String) -> String? {
                rootEl.elements(forLocalName: name).first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let t = value("Title"), !t.isEmpty {
                title = [value("Series"), value("Number").map { "#\($0)" }, t].compactMap { $0 }.joined(separator: " ")
            }
            author = value("Writer")
            rtl = value("Manga") == "YesAndRightToLeft"
        }

        // Folder boundaries become chapters.
        var toc: [TOCEntry] = []
        var lastFolder: String?
        for (i, image) in images.enumerated() {
            let folder = image.deletingLastPathComponent().path
            if folder != lastFolder {
                let name = image.deletingLastPathComponent().lastPathComponent
                toc.append(TOCEntry(title: folder == root.path || name == "pages" ? "Page \(i + 1)" : name, spineIndex: i))
                lastFolder = folder
            }
        }
        if toc.count <= 1 { toc = [TOCEntry(title: "Cover", spineIndex: 0)] }

        return Publication(kind: .comic, title: title, author: author, language: nil,
                           spine: images.map { SpineItem(url: $0, weight: 1) }, toc: toc,
                           coverURL: images.first, rightToLeft: rtl, rootDirectory: root, sourceURL: url)
    }
}

enum PDFMetadata {
    static func publication(_ url: URL) throws -> Publication {
        guard let doc = PDFDocument(url: url) else { throw PublicationError.corrupt("not a valid PDF") }
        if doc.isLocked && !doc.unlock(withPassword: "") { throw PublicationError.corrupt("the PDF is password-protected") }
        let attrs = doc.documentAttributes ?? [:]
        let title = (attrs[PDFDocumentAttribute.titleAttribute] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? url.deletingPathExtension().lastPathComponent
        let author = (attrs[PDFDocumentAttribute.authorAttribute] as? String).flatMap { $0.isEmpty ? nil : $0 }

        func entries(_ outline: PDFOutline) -> [TOCEntry] {
            (0..<outline.numberOfChildren).compactMap { i in
                guard let child = outline.child(at: i) else { return nil }
                let page = child.destination?.page.map { doc.index(for: $0) } ?? 0
                return TOCEntry(title: child.label ?? "Untitled", spineIndex: page, children: entries(child))
            }
        }
        let toc = doc.outlineRoot.map(entries) ?? []
        let pages = (0..<max(1, doc.pageCount)).map { _ in SpineItem(url: url, weight: 1) }
        return Publication(kind: .pdf, title: title, author: author, language: nil, spine: pages, toc: toc,
                           coverURL: nil, rootDirectory: url.deletingLastPathComponent(), sourceURL: url)
    }
}
