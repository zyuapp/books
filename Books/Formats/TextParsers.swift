import AppKit
import Foundation

/// Plain text and Markdown → XHTML chapters.
enum TextParser {
    static func parsePlainText(_ url: URL, into dir: URL) throws -> Publication {
        var text = try decodeText(url)
        func header(_ key: String) -> String? {
            guard let r = text.range(of: "(?m)^\(key): *([^\r\n]+)", options: .regularExpression) else { return nil }
            return String(text[r].dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
        }
        let headerTitle = header("Title"), headerAuthor = header("Author")
        text = stripGutenbergBoilerplate(text)
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")

        // Paragraphs are separated by blank lines; hard-wrapped lines are joined.
        var paragraphs: [String] = []
        var current: [String] = []
        func flush() {
            if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }
            current = []
        }
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { flush() } else { current.append(trimmed) }
        }
        flush()

        let headingPattern = try NSRegularExpression(
            pattern: #"^(chapter|book|part|section|volume|prologue|epilogue|introduction|preface|appendix|letter|stave|canto)\b[\s\.\:]*([0-9]+|[ivxlcdm]+\b|[a-z\-]+)?[\.\:]?(\s.{0,80})?$"#,
            options: [.caseInsensitive]
        )
        func isHeading(_ p: String) -> Bool {
            p.count < 100 && headingPattern.firstMatch(in: p, range: NSRange(p.startIndex..., in: p)) != nil
        }

        struct Chapter { var title: String; var paragraphs: [String] }
        var chapters: [Chapter] = [Chapter(title: "Beginning", paragraphs: [])]
        let headingCount = paragraphs.filter(isHeading).count
        let useHeadings = headingCount >= 2
        for p in paragraphs {
            if useHeadings && isHeading(p) {
                chapters.append(Chapter(title: p, paragraphs: [p]))
            } else {
                chapters[chapters.count - 1].paragraphs.append(p)
            }
        }
        if chapters.first?.paragraphs.isEmpty == true { chapters.removeFirst() }
        // Long unstructured text is split into ~40 KB sections.
        if !useHeadings {
            var sized: [Chapter] = []
            var bucket: [String] = []
            var size = 0
            for p in paragraphs {
                bucket.append(p)
                size += p.utf8.count
                if size > 40_000 {
                    sized.append(Chapter(title: "Part \(sized.count + 1)", paragraphs: bucket))
                    bucket = []
                    size = 0
                }
            }
            if !bucket.isEmpty || sized.isEmpty { sized.append(Chapter(title: "Part \(sized.count + 1)", paragraphs: bucket)) }
            chapters = sized
        }

        let title = headerTitle ?? guessTitle(paragraphs) ?? url.deletingPathExtension().lastPathComponent
        var spine: [SpineItem] = []
        var toc: [TOCEntry] = []
        for (i, chapter) in chapters.enumerated() {
            let body = chapter.paragraphs.enumerated().map { j, p in
                j == 0 && useHeadings && isHeading(p)
                    ? "<h2>\(p.xmlEscaped)</h2>" : "<p>\(p.xmlEscaped)</p>"
            }.joined(separator: "\n")
            let file = dir.appendingPathComponent("text\(i).html")
            let html = HTMLTemplate.document(title: chapter.title, body: body, css: "h2 { text-align: center; margin: 2em 0 1em; }")
            try html.write(to: file, atomically: true, encoding: .utf8)
            spine.append(SpineItem(url: file, weight: html.utf8.count))
            toc.append(TOCEntry(title: chapter.title.count > 60 ? String(chapter.title.prefix(60)) + "…" : chapter.title, spineIndex: i))
        }
        return Publication(kind: .reflowable, title: title, author: headerAuthor ?? guessAuthor(paragraphs), language: nil,
                           spine: spine, toc: toc, coverURL: nil, rootDirectory: dir, sourceURL: url)
    }

    static func parseMarkdown(_ url: URL, into dir: URL) throws -> Publication {
        let text = try decodeText(url)
        let blocks = Markdown.blocks(text)
        let h1Count = blocks.filter { if case .heading(1, _) = $0 { true } else { false } }.count
        let splitLevel = h1Count >= 2 ? 1 : 2

        var chapters: [(title: String, blocks: [Markdown.Block])] = [("Beginning", [])]
        var title: String?
        for block in blocks {
            if case .heading(let level, let t) = block {
                if title == nil && level == 1 { title = Markdown.plain(t) }
                if level <= splitLevel && !(chapters.count == 1 && chapters[0].blocks.isEmpty) {
                    chapters.append((Markdown.plain(t), [block]))
                    continue
                } else if level <= splitLevel {
                    chapters[0].title = Markdown.plain(t)
                }
            }
            chapters[chapters.count - 1].blocks.append(block)
        }

        let base = url.deletingLastPathComponent()
        var spine: [SpineItem] = []
        var toc: [TOCEntry] = []
        for (i, chapter) in chapters.enumerated() {
            var subs: [TOCEntry] = []
            var body = ""
            for (j, block) in chapter.blocks.enumerated() {
                if case .heading(let level, let t) = block, level == splitLevel + 1 {
                    subs.append(TOCEntry(title: Markdown.plain(t), spineIndex: i, fragment: "md-\(j)"))
                }
                body += Markdown.html(block, id: "md-\(j)", base: base)
            }
            let file = dir.appendingPathComponent("md\(i).html")
            let html = HTMLTemplate.document(title: chapter.title, body: body,
                                             css: "pre { white-space: pre-wrap; } img { max-width: 100%; }")
            try html.write(to: file, atomically: true, encoding: .utf8)
            spine.append(SpineItem(url: file, weight: html.utf8.count))
            toc.append(TOCEntry(title: chapter.title, spineIndex: i, children: subs))
        }
        return Publication(kind: .reflowable, title: title ?? url.deletingPathExtension().lastPathComponent,
                           author: nil, language: nil, spine: spine, toc: toc, coverURL: nil,
                           rootDirectory: URL(fileURLWithPath: "/"), sourceURL: url)
    }

    static func decodeText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let s = String(data: data, encoding: .utf16) { return s }
        if let s = String(data: data, encoding: .utf8) { return s }
        var converted: NSString?
        let enc = NSString.stringEncoding(for: data, encodingOptions: [:], convertedString: &converted, usedLossyConversion: nil)
        if enc != 0, let converted { return converted as String }
        if let s = String(data: data, encoding: .windowsCP1252) { return s }
        throw PublicationError.corrupt("unknown text encoding")
    }

    private static func stripGutenbergBoilerplate(_ text: String) -> String {
        var t = text
        if let start = t.range(of: #"\*\*\* ?START OF (THE|THIS) PROJECT GUTENBERG[^\r\n]*"#, options: .regularExpression) {
            t = String(t[start.upperBound...])
        }
        if let end = t.range(of: #"\*\*\* ?END OF (THE|THIS) PROJECT GUTENBERG"#, options: .regularExpression) {
            t = String(t[..<end.lowerBound])
        }
        return t
    }

    private static func guessTitle(_ paragraphs: [String]) -> String? {
        guard let first = paragraphs.first(where: { !$0.isEmpty && !$0.hasPrefix("[") }), first.count < 80 else { return nil }
        return first
    }

    private static func guessAuthor(_ paragraphs: [String]) -> String? {
        for p in paragraphs.prefix(6) where p.lowercased().hasPrefix("by ") && p.count < 80 {
            return String(p.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}

/// RTF, RTFD, DOCX, ODT, DOC and HTML via AppKit's text system.
enum RichTextParser {
    static func parse(_ url: URL, into dir: URL) throws -> Publication {
        let ext = url.lowercaseExtension
        if ext == "html" || ext == "htm" || ext == "xhtml" {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 1000
            let title = (try? String(contentsOf: url, encoding: .utf8)).flatMap { html -> String? in
                guard let r = html.range(of: #"(?<=<title>)[^<]+"#, options: .regularExpression) else { return nil }
                return String(html[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return Publication(kind: .reflowable, title: title ?? url.deletingPathExtension().lastPathComponent,
                               author: nil, language: nil, spine: [SpineItem(url: url, weight: size)],
                               toc: [TOCEntry(title: title ?? "Beginning", spineIndex: 0)], coverURL: nil,
                               rootDirectory: url.deletingLastPathComponent(), sourceURL: url)
        }
        let types: [String: NSAttributedString.DocumentType] = [
            "rtf": .rtf, "rtfd": .rtfd, "docx": .officeOpenXML, "odt": .openDocument, "doc": .docFormat,
        ]
        var attrs: NSDictionary?
        let attributed = try NSAttributedString(
            url: url, options: types[ext].map { [.documentType: $0] } ?? [:], documentAttributes: &attrs)
        let html = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.html,
                                 .characterEncoding: String.Encoding.utf8.rawValue])
        let file = dir.appendingPathComponent("document.html")
        try html.write(to: file)
        let docTitle = (attrs?[NSAttributedString.DocumentAttributeKey.title] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let author = (attrs?[NSAttributedString.DocumentAttributeKey.author] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let title = docTitle ?? url.deletingPathExtension().lastPathComponent
        return Publication(kind: .reflowable, title: title, author: author, language: nil,
                           spine: [SpineItem(url: file, weight: html.count)],
                           toc: [TOCEntry(title: title, spineIndex: 0)], coverURL: nil,
                           rootDirectory: dir, sourceURL: url)
    }
}

/// Minimal CommonMark-ish renderer for reading Markdown files.
enum Markdown {
    enum Block {
        case heading(Int, String)
        case paragraph(String)
        case code(String)
        case quote([String])
        case list(ordered: Bool, items: [String])
        case rule
    }

    static func blocks(_ text: String) -> [Block] {
        var result: [Block] = []
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var i = 0
        var para: [String] = []
        func flushPara() {
            if !para.isEmpty { result.append(.paragraph(para.joined(separator: " "))) }
            para = []
        }
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushPara()
                var code: [String] = []
                i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(String(trimmed.prefix(3))) {
                    code.append(lines[i]); i += 1
                }
                result.append(.code(code.joined(separator: "\n")))
            } else if trimmed.isEmpty {
                flushPara()
            } else if let m = trimmed.firstMatch(of: /^(#{1,6})\s+(.*?)\s*#*$/) {
                flushPara()
                result.append(.heading(m.1.count, String(m.2)))
            } else if trimmed.wholeMatch(of: /([-*_])(\s*\1){2,}/) != nil {
                flushPara()
                result.append(.rule)
            } else if trimmed.hasPrefix(">") {
                flushPara()
                var q: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    q.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                result.append(.quote(q))
                continue
            } else if trimmed.firstMatch(of: /^([-*+]|\d+[.)])\s+/) != nil {
                flushPara()
                let ordered = trimmed.first!.isNumber
                var items: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if let m = t.firstMatch(of: /^([-*+]|\d+[.)])\s+(.*)/) {
                        items.append(String(m.2))
                    } else if !t.isEmpty, lines[i].hasPrefix("  "), !items.isEmpty {
                        items[items.count - 1] += " " + t
                    } else { break }
                    i += 1
                }
                result.append(.list(ordered: ordered, items: items))
                continue
            } else if i + 1 < lines.count, para.isEmpty,
                      lines[i + 1].wholeMatch(of: /\s*(=+|-+)\s*/) != nil {
                result.append(.heading(lines[i + 1].contains("=") ? 1 : 2, trimmed))
                i += 1
            } else {
                para.append(trimmed)
            }
            i += 1
        }
        flushPara()
        return result
    }

    static func html(_ block: Block, id: String, base: URL?) -> String {
        switch block {
        case .heading(let l, let t): return "<h\(l) id=\"\(id)\">\(inline(t, base: base))</h\(l)>\n"
        case .paragraph(let t): return "<p>\(inline(t, base: base))</p>\n"
        case .code(let c): return "<pre><code>\(c.xmlEscaped)</code></pre>\n"
        case .quote(let lines):
            let inner = blocks(lines.joined(separator: "\n")).map { html($0, id: "", base: base) }.joined()
            return "<blockquote>\(inner)</blockquote>\n"
        case .list(let ordered, let items):
            let tag = ordered ? "ol" : "ul"
            return "<\(tag)>" + items.map { "<li>\(inline($0, base: base))</li>" }.joined() + "</\(tag)>\n"
        case .rule: return "<hr/>\n"
        }
    }

    static func inline(_ text: String, base: URL?) -> String {
        var s = text.xmlEscaped
        s = s.replacing(/`([^`]+)`/) { "<code>\($0.1)</code>" }
        s = s.replacing(/!\[([^\]]*)\]\(([^)\s]+)[^)]*\)/) { m in
            let src = String(m.2)
            let resolved = src.contains("://") ? src : (base?.appendingPathComponent(src).absoluteString ?? src)
            return "<img alt=\"\(m.1)\" src=\"\(resolved)\"/>"
        }
        s = s.replacing(/\[([^\]]+)\]\(([^)\s]+)[^)]*\)/) { "<a href=\"\($0.2)\">\($0.1)</a>" }
        s = s.replacing(/(\*\*|__)(.+?)\1/) { "<strong>\($0.2)</strong>" }
        s = s.replacing(/(\*|_)(.+?)\1/) { "<em>\($0.2)</em>" }
        s = s.replacing(/~~(.+?)~~/) { "<s>\($0.1)</s>" }
        return s
    }

    static func plain(_ text: String) -> String {
        text.replacing(/[*_`#\[\]]|\([^)]*\)/, with: "").trimmingCharacters(in: .whitespaces)
    }

    /// Block-level rendering for chat answers.
    static func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
