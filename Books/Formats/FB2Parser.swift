import Foundation

/// FictionBook 2 (.fb2, .fb2.zip, .fbz) → XHTML chapters.
enum FB2Parser {
    static func parse(_ url: URL, into dir: URL) throws -> Publication {
        var xmlURL = url
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".fbz") || name.hasSuffix(".zip") {
            let unpacked = dir.appendingPathComponent("archive", isDirectory: true)
            try Archive.extract(url, to: unpacked)
            guard let fb2 = Archive.files(in: unpacked).first(where: { $0.lowercaseExtension == "fb2" })
            else { throw PublicationError.corrupt("no .fb2 file inside the archive") }
            xmlURL = fb2
        }
        guard let doc = try? XMLDocument(contentsOf: xmlURL, options: [.nodeLoadExternalEntitiesNever]),
              let root = doc.rootElement()
        else { throw PublicationError.corrupt("invalid FictionBook XML") }

        let imagesDir = dir.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)

        // Binaries (images).
        var imageFiles: [String: String] = [:]
        for binary in root.elements(forLocalName: "binary") {
            guard let id = binary.attribute(forName: "id")?.stringValue,
                  let b64 = binary.stringValue,
                  let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else { continue }
            let type = binary.attribute(forName: "content-type")?.stringValue ?? ""
            let ext = type.contains("png") ? "png" : type.contains("gif") ? "gif" : "jpg"
            let safe = id.replacingOccurrences(of: "/", with: "_")
            let file = safe.lowercased().hasSuffix(".\(ext)") ? safe : "\(safe).\(ext)"
            try? data.write(to: imagesDir.appendingPathComponent(file))
            imageFiles[id] = file
        }

        let description = root.elements(forLocalName: "description").first
        let titleInfo = description?.elements(forLocalName: "title-info").first
        let title = titleInfo?.elements(forLocalName: "book-title").first?.stringValue?.collapsingWhitespace
            ?? url.deletingPathExtension().lastPathComponent
        let authors = (titleInfo?.elements(forLocalName: "author") ?? []).map { a in
            ["first-name", "middle-name", "last-name"]
                .compactMap { a.elements(forLocalName: $0).first?.stringValue?.collapsingWhitespace }
                .filter { !$0.isEmpty }.joined(separator: " ")
        }.filter { !$0.isEmpty }
        let lang = titleInfo?.elements(forLocalName: "lang").first?.stringValue
        var coverURL: URL?
        if let img = titleInfo?.elements(forLocalName: "coverpage").first?.elements(forLocalName: "image").first,
           let href = Self.href(img), let file = imageFiles[String(href.drop(while: { $0 == "#" }))] {
            coverURL = imagesDir.appendingPathComponent(file)
        }

        // Chapters: each top-level <section> of each <body>; notes bodies become one chapter.
        struct Chapter { var element: XMLElement; var title: String; var isNotes: Bool; var wrapper: [XMLElement] }
        var chapters: [Chapter] = []
        for body in root.elements(forLocalName: "body") {
            let bodyName = body.attribute(forName: "name")?.stringValue ?? ""
            if !bodyName.isEmpty {
                chapters.append(Chapter(element: body, title: bodyName.capitalized == "Notes" ? "Notes" : bodyName.capitalized, isNotes: true, wrapper: []))
                continue
            }
            let sections = body.elements(forLocalName: "section")
            let preface = (body.children ?? []).compactMap { $0 as? XMLElement }.filter { $0.localName != "section" }
            if sections.isEmpty {
                chapters.append(Chapter(element: body, title: title, isNotes: false, wrapper: []))
            } else {
                for (i, s) in sections.enumerated() {
                    let t = s.elements(forLocalName: "title").first?.stringValue?.collapsingWhitespace
                    chapters.append(Chapter(element: s, title: (t?.isEmpty == false ? t! : "Chapter \(i + 1)"), isNotes: false, wrapper: i == 0 ? preface : []))
                }
            }
        }
        guard !chapters.isEmpty else { throw PublicationError.corrupt("the book has no body") }

        // Map element ids to chapter files so links resolve across chapters.
        var idToFile: [String: String] = [:]
        for (i, chapter) in chapters.enumerated() {
            let file = "chapter\(i).html"
            for el in [chapter.element] + chapter.wrapper { collectIDs(el) { idToFile[$0] = file } }
        }

        let css = """
        .fb-title { text-align: center; margin: 1.5em 0 1em; }
        .fb-epigraph, .fb-cite { margin: 1em 2em; font-style: italic; }
        .fb-poem { margin: 1em 2em; } .fb-stanza { margin: 0.8em 0; } .fb-v { margin: 0; text-indent: 0; }
        .fb-author { text-align: right; font-style: italic; }
        .fb-subtitle { text-align: center; font-weight: 600; }
        img { max-width: 100%; display: block; margin: 1em auto; }
        """
        var spine: [SpineItem] = []
        var toc: [TOCEntry] = []
        for (i, chapter) in chapters.enumerated() {
            if !chapter.isNotes {
                for (j, sub) in chapter.element.elements(forLocalName: "section").enumerated()
                where sub.attribute(forName: "id") == nil {
                    sub.addAttribute(XMLNode.attribute(withName: "id", stringValue: "fbsec-\(i)-\(j)") as! XMLNode)
                }
            }
            var converter = Converter(imageFiles: imageFiles, idToFile: idToFile, currentFile: "chapter\(i).html")
            var body = chapter.wrapper.map { converter.html($0, depth: 1) }.joined()
            if chapter.isNotes {
                body += "<h1 class=\"fb-title\">\(chapter.title.xmlEscaped)</h1>"
                body += (chapter.element.children ?? []).compactMap { $0 as? XMLElement }.map { converter.html($0, depth: 2) }.joined()
            } else {
                body += converter.sectionContents(chapter.element, depth: 1)
            }
            let html = HTMLTemplate.document(title: chapter.title, body: body, css: css, lang: lang)
            let fileURL = dir.appendingPathComponent("chapter\(i).html")
            try html.write(to: fileURL, atomically: true, encoding: .utf8)
            spine.append(SpineItem(url: fileURL, weight: html.utf8.count))
            var entry = TOCEntry(title: chapter.title, spineIndex: i)
            if !chapter.isNotes {
                entry.children = chapter.element.elements(forLocalName: "section").compactMap { sub in
                    guard let t = sub.elements(forLocalName: "title").first?.stringValue?.collapsingWhitespace, !t.isEmpty else { return nil }
                    return TOCEntry(title: t, spineIndex: i, fragment: sub.attribute(forName: "id")?.stringValue)
                }
            }
            toc.append(entry)
        }

        return Publication(
            kind: .reflowable, title: title,
            author: authors.isEmpty ? nil : authors.joined(separator: ", "),
            language: lang, spine: spine, toc: toc, coverURL: coverURL,
            rootDirectory: dir, sourceURL: url
        )
    }

    fileprivate static func href(_ el: XMLElement) -> String? {
        el.attributes?.first(where: { $0.localName == "href" })?.stringValue
    }

    private static func collectIDs(_ el: XMLElement, _ add: (String) -> Void) {
        if let id = el.attribute(forName: "id")?.stringValue { add(id) }
        for child in el.children ?? [] { if let c = child as? XMLElement { collectIDs(c, add) } }
    }

    private struct Converter {
        let imageFiles: [String: String]
        let idToFile: [String: String]
        let currentFile: String
        init(imageFiles: [String: String], idToFile: [String: String], currentFile: String) {
            self.imageFiles = imageFiles
            self.idToFile = idToFile
            self.currentFile = currentFile
        }

        mutating func sectionContents(_ section: XMLElement, depth: Int) -> String {
            var out = ""
            for child in section.children ?? [] {
                if let el = child as? XMLElement { out += html(el, depth: depth) }
            }
            return out
        }

        private func idAttr(_ el: XMLElement) -> String {
            el.attribute(forName: "id")?.stringValue.map { " id=\"\($0.xmlEscaped)\"" } ?? ""
        }

        mutating func inline(_ node: XMLNode) -> String {
            if node.kind == .text { return (node.stringValue ?? "").xmlEscaped }
            guard let el = node as? XMLElement else { return "" }
            let inner = (el.children ?? []).map { inline($0) }.joined()
            switch el.localName {
            case "strong": return "<strong>\(inner)</strong>"
            case "emphasis": return "<em>\(inner)</em>"
            case "strikethrough": return "<s>\(inner)</s>"
            case "sub": return "<sub>\(inner)</sub>"
            case "sup": return "<sup>\(inner)</sup>"
            case "code": return "<code>\(inner)</code>"
            case "a":
                let raw = FB2Parser.href(el) ?? ""
                var target = raw
                if raw.hasPrefix("#") {
                    let id = String(raw.dropFirst())
                    let file = idToFile[id] ?? currentFile
                    target = (file == currentFile ? "" : file) + "#" + id
                }
                let isNote = el.attribute(forName: "type")?.stringValue == "note"
                let body = isNote ? "<sup>\(inner)</sup>" : inner
                return "<a href=\"\(target.xmlEscaped)\"\(isNote ? " epub:type=\"noteref\" class=\"fb-noteref\"" : "")>\(body)</a>"
            case "image":
                return image(el)
            default: return inner
            }
        }

        private func image(_ el: XMLElement) -> String {
            guard let href = FB2Parser.href(el), let file = imageFiles[String(href.drop(while: { $0 == "#" }))]
            else { return "" }
            return "<img src=\"images/\(file.xmlEscaped)\" alt=\"\"\(idAttr(el))/>"
        }

        mutating func html(_ el: XMLElement, depth: Int) -> String {
            let inner: () -> String = { [self] in
                var copy = self
                return (el.children ?? []).map { copy.inline($0) }.joined()
            }
            let blocks: (Int) -> String = { [self] d in
                var copy = self
                return (el.children ?? []).compactMap { $0 as? XMLElement }.map { copy.html($0, depth: d) }.joined()
            }
            switch el.localName {
            case "title":
                let h = min(depth, 6)
                let paras = el.elements(forLocalName: "p").map { p -> String in
                    var copy = self
                    return (p.children ?? []).map { copy.inline($0) }.joined()
                }
                return "<h\(h) class=\"fb-title\">\(paras.joined(separator: "<br/>"))</h\(h)>"
            case "section":
                return "<section\(idAttr(el))>\(blocks(depth + 1))</section>"
            case "p": return "<p\(idAttr(el))>\(inner())</p>"
            case "subtitle": return "<p class=\"fb-subtitle\"\(idAttr(el))>\(inner())</p>"
            case "empty-line": return "<p>&#160;</p>"
            case "epigraph": return "<blockquote class=\"fb-epigraph\"\(idAttr(el))>\(blocks(depth))</blockquote>"
            case "cite": return "<blockquote class=\"fb-cite\"\(idAttr(el))>\(blocks(depth))</blockquote>"
            case "poem": return "<div class=\"fb-poem\"\(idAttr(el))>\(blocks(depth))</div>"
            case "stanza": return "<div class=\"fb-stanza\">\(blocks(depth))</div>"
            case "v": return "<p class=\"fb-v\">\(inner())</p>"
            case "text-author": return "<p class=\"fb-author\">\(inner())</p>"
            case "image": return image(el)
            case "table": return "<table\(idAttr(el))>\(blocks(depth))</table>"
            case "tr": return "<tr>\(blocks(depth))</tr>"
            case "td", "th":
                let tag = el.localName!
                return "<\(tag)>\(inner())</\(tag)>"
            case "annotation": return "<div class=\"fb-annotation\">\(blocks(depth))</div>"
            default: return blocks(depth)
            }
        }
    }
}
