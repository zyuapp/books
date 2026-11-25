import Foundation

extension MOBIParser {
    static func buildMOBI6(_ db: PalmDB, _ h: Header, resources: [Int: String], title: String, language: String?) throws -> Built {
        let raw = try extractText(db, h)
        guard !raw.isEmpty else { throw PublicationError.corrupt("no text") }
        let utf8 = h.isUTF8

        // Every filepos target (links, guide, NCX) gets an `<a id="fileposN">` anchor in the raw markup.
        let latin = String(decoding: raw.map { $0 < 0x80 ? $0 : 0x3F }, as: UTF8.self)
        var positions = Set(HTML.matches(latin, "filepos\\s*=\\s*['\"]?0*(\\d{1,10})").compactMap { $0.groups[1].flatMap { Int($0) } })
        var ncx: MOBIIndex?
        if let n = h.ncx, let index = try? readIndex(db, n, utf8: utf8) {
            ncx = index
            for e in index.entries { if let p = e.tags[1]?.first { positions.insert(p) } }
        }
        var marked = [UInt8]()
        marked.reserveCapacity(raw.count + positions.count * 32)
        var last = 0
        for p in positions.filter({ $0 > 0 && $0 < raw.count }).sorted() {
            let at = max(anchorPoint(raw, p), last)
            marked += raw[last..<at]
            marked += Array("<a id=\"filepos\(p)\"></a>".utf8)
            last = at
        }
        marked += raw[last...]
        let html = decodeText(marked, utf8: utf8)

        var tocPos: Int?
        for m in HTML.matches(html, "<reference\\b[^>]*>") {
            guard let tag = m.groups[0], HTML.firstMatch(tag, "type\\s*=\\s*[\"']?toc\\b") != nil,
                  let fp = HTML.firstMatch(tag, "filepos\\s*=\\s*[\"']?0*(\\d+)")?.groups[1] else { continue }
            tocPos = Int(fp)
            break
        }

        let ns = html as NSString
        var bodyStart = 0, bodyEnd = ns.length
        if let b = HTML.firstMatch(html, "<body\\b[^>]*>") ?? HTML.firstMatch(html, "</head\\s*>") { bodyStart = NSMaxRange(b.range) }
        if let e = HTML.matches(html, "</body\\s*>").last, e.range.location >= bodyStart { bodyEnd = e.range.location }
        let head = ns.substring(to: bodyStart)
        let styles = HTML.matches(head, "<style\\b[^>]*>[\\s\\S]*?</style\\s*>").compactMap { $0.groups[0] }.joined(separator: "\n")
        let body = ns.substring(with: NSRange(location: bodyStart, length: bodyEnd - bodyStart))

        // Split at page breaks, folding tiny fragments into the next one.
        var chapters: [String] = []
        var pending = ""
        for chunk in HTML.split(body, "<mbp:pagebreak\\b[^>]*>|</mbp:pagebreak\\s*>") {
            pending += chunk
            if HTML.textWeight(pending) >= 600 {
                chapters.append(pending)
                pending = ""
            }
        }
        if !pending.isEmpty {
            if chapters.isEmpty || HTML.textWeight(pending) >= 200 { chapters.append(pending) } else { chapters[chapters.count - 1] += pending }
        }

        chapters = chapters.map { c in
            var c = HTML.replace(c, "</?mbp:[^>]*>") { _ in "" }
            c = HTML.replace(c, "\\sfilepos\\s*=\\s*[\"']?0*(\\d+)[\"']?") { g in " href=\"#filepos\(g[1] ?? "0")\"" }
            c = HTML.replace(c, "<img\\b[^>]*>") { g in imageTag(g[0] ?? "", resources: resources) }
            c = HTML.replace(c, "</(?:br|img|hr)\\s*>") { _ in "" }
            c = HTML.replace(c, "<(?:p|div|blockquote)\\b[^>]*\\s(?:width|height)\\s*=[^>]*>") { g in blockStyle(g[0] ?? "") }
            return HTML.expandSelfClosing(c)
        }

        var chapterOf: [String: Int] = [:]
        for (i, c) in chapters.enumerated() {
            for m in HTML.matches(c, "\\sid=\"(filepos\\d+)\"", options: []) { if let id = m.groups[1] { chapterOf[id] = i } }
        }
        let names = chapters.indices.map { String(format: "chapter%03d.html", $0 + 1) }
        func target(_ pos: Int) -> (spine: Int, fragment: String?) {
            let id = "filepos\(pos)"
            if let c = chapterOf[id] { return (c, id) }
            return (0, nil)
        }

        var toc: [TOCEntry] = []
        if let ncx {
            let items = ncx.entries.map { e in
                NCXItem(title: (ncx.string(e.tags[3]?.first) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                        parent: e.tags[21]?.first, target: e.tags[1]?.first.map(target))
            }
            toc = buildTOC(items)
        }
        if toc.isEmpty, let tocPos, let c = chapterOf["filepos\(tocPos)"] {
            let chapter = chapters[c] as NSString
            let anchor = chapter.range(of: "id=\"filepos\(tocPos)\"")
            let tail = anchor.location == NSNotFound ? chapter as String : chapter.substring(from: anchor.location)
            for source in [tail, chapters[c]] {
                toc = HTML.matches(source, "<a\\b[^>]*href=\"#filepos(\\d+)\"[^>]*>([\\s\\S]*?)</a\\s*>").compactMap { m in
                    guard let p = m.groups[1].flatMap({ Int($0) }), p != tocPos, let c = chapterOf["filepos\(p)"] else { return nil }
                    let title = HTML.plainText(m.groups[2] ?? "")
                    return title.isEmpty ? nil : TOCEntry(title: title, spineIndex: c, fragment: "filepos\(p)")
                }
                if toc.count >= 2 { break }
            }
            if toc.count < 2 { toc = [] }
        }

        var built = Built()
        let langAttr = language.map { " lang=\"\(HTML.escape($0))\"" } ?? ""
        var docs: [String] = []
        for (i, c) in chapters.enumerated() {
            let linked = HTML.replace(c, "href=\"#(filepos\\d+)\"", options: []) { g in
                let id = g[1] ?? ""
                return chapterOf[id].map { "href=\"\(names[$0])#\(id)\"" } ?? "href=\"\(names[0])\""
            }
            let doc = """
            <!DOCTYPE html>
            <html\(langAttr)><head><meta charset="utf-8"><title>\(HTML.escape(title))</title>
            <style>img { max-width: 100%; height: auto; }</style>\(styles)</head>
            <body>\(linked)</body></html>
            """
            docs.append(doc)
            built.files.append(OutputFile(path: names[i], content: doc))
            built.spine.append((names[i], HTML.textWeight(linked)))
        }
        built.toc = toc.isEmpty ? HTML.headingTOC(docs) : toc
        return built
    }

    /// Where to put the anchor for a filepos: after the tag if it points inside one or at a page break,
    /// never inside an entity.
    private static func anchorPoint(_ b: [UInt8], _ p: Int) -> Int {
        let lt = UInt8(ascii: "<"), gt = UInt8(ascii: ">")
        let window = b[p..<min(b.count, p + 65536)]
        if b[p] == lt {
            let tag = String(decoding: b[p..<min(b.count, p + 15)], as: UTF8.self).lowercased()
            if tag.hasPrefix("<mbp:pagebreak"), let end = window.firstIndex(of: gt) { return end + 1 }
            return p
        }
        if let end = window.firstIndex(of: gt), window.firstIndex(of: lt).map({ end < $0 }) ?? true { return end + 1 }
        var j = p - 1
        while j >= max(0, p - 12) {
            let c = b[j]
            if c == UInt8(ascii: "&") {
                if let semi = b[p..<min(b.count, p + 12)].firstIndex(of: UInt8(ascii: ";")) { return semi + 1 }
                break
            }
            if [UInt8(ascii: ";"), lt, gt, 0x20, 0x0A, 0x0D, 0x09].contains(c) { break }
            j -= 1
        }
        return p
    }

    /// MOBI `<p width="2em" height="1em">` mean text-indent and top margin.
    private static func blockStyle(_ tag: String) -> String {
        var css: [String] = []
        let t = HTML.replace(tag, "\\s(width|height)\\s*=\\s*[\"']?(-?[0-9.]+)(em|pt|px|%)?[\"']?") { g in
            guard let v = g[2], let n = Double(v) else { return "" }
            if n != 0 { css.append("\(g[1]?.lowercased() == "width" ? "text-indent" : "margin-top"): \(v)\(g[3] ?? "px")") }
            return ""
        }
        guard !css.isEmpty, HTML.firstMatch(t, "\\sstyle\\s*=") == nil, let space = t.firstIndex(where: { $0 == " " || $0 == ">" }) else { return t }
        return String(t[..<space]) + " style=\"\(css.joined(separator: "; "))\"" + t[space...]
    }

    private static func imageTag(_ tag: String, resources: [Int: String]) -> String {
        var index: Int?
        for attr in ["recindex", "hirecindex", "lorecindex"] {
            if let v = HTML.firstMatch(tag, "\\s\(attr)\\s*=\\s*[\"']?(\\d+)")?.groups[1], let n = Int(v), resources[n] != nil {
                index = n
                break
            }
        }
        var t = HTML.replace(tag, "\\s(?:hi|lo)?recindex\\s*=\\s*(?:\"[^\"]*\"|'[^']*'|[^\\s>]+)") { _ in "" }
        if let index, let path = resources[index], HTML.firstMatch(t, "\\ssrc\\s*=") == nil {
            t = "<img src=\"\(path)\"" + t.dropFirst(4)
        }
        return t
    }

    /// Plain PalmDOC (TEXtREAd) text.
    static func buildPlainText(_ db: PalmDB, _ h: Header, title: String) throws -> Built {
        let text = decodeText(try extractText(db, h), utf8: false).replacingOccurrences(of: "\r\n", with: "\n")
        var built = Built()
        var chunk = ""
        func flush() {
            guard !chunk.isEmpty else { return }
            let name = String(format: "chapter%03d.html", built.spine.count + 1)
            let doc = "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"><title>\(HTML.escape(title))</title></head><body>\(chunk)</body></html>"
            built.files.append(OutputFile(path: name, content: doc))
            built.spine.append((name, HTML.textWeight(chunk)))
            chunk = ""
        }
        for para in text.components(separatedBy: "\n\n") {
            let p = para.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !p.isEmpty else { continue }
            chunk += "<p>\(HTML.escape(p).replacingOccurrences(of: "\n", with: "<br>"))</p>\n"
            if chunk.utf8.count > 64_000 { flush() }
        }
        flush()
        guard !built.spine.isEmpty else { throw PublicationError.corrupt("no text") }
        built.toc = built.spine.indices.map { TOCEntry(title: "Part \($0 + 1)", spineIndex: $0) }
        return built
    }
}
