import Foundation

extension MOBIParser {
    struct OutputFile {
        let path: String
        let content: String
    }

    /// Rendered book: files relative to the output directory, spine paths into `files`.
    struct Built {
        var files: [OutputFile] = []
        var spine: [(path: String, weight: Int)] = []
        var toc: [TOCEntry] = []
    }

    private struct Part {
        var bytes: [UInt8]
        let start: Int
        var end: Int { start + bytes.count }
    }

    private static let base32 = "[0-9A-Va-v]"

    static func buildKF8(_ db: PalmDB, _ h: Header, resources: [Int: String]) throws -> Built {
        let text = try extractText(db, h)
        guard !text.isEmpty else { throw PublicationError.corrupt("no text in KF8 section") }
        let utf8 = h.isUTF8

        var flows: [Range<Int>] = []
        if let f = h.fdst {
            let r = db.record(f)
            if BE.hasPrefix(r, "FDST"), let n = BE.u32(r, 8) {
                for i in 0..<min(n, 4096) {
                    guard let s = BE.u32(r, 12 + i * 8), let e = BE.u32(r, 16 + i * 8) else { break }
                    let lo = min(s, text.count)
                    flows.append(lo..<min(max(e, lo), text.count))
                }
            }
        }
        if flows.isEmpty { flows = [0..<text.count] }

        // Reassemble each skeleton with its fragments.
        var frags: [(insertPos: Int, length: Int)] = []
        var parts: [Part] = []
        if let skelIdx = h.skel, let fragIdx = h.frag {
            for e in try readIndex(db, fragIdx, utf8: utf8).entries {
                guard let pos = Int(e.name.trimmingCharacters(in: .whitespaces)), pos >= 0, pos < 1 << 40,
                      let t = e.tags[6], t.count >= 2 else { continue }
                frags.append((pos, min(t[1], text.count)))
            }
            var fragPtr = 0
            for e in try readIndex(db, skelIdx, utf8: utf8).entries {
                guard let fragCount = e.tags[1]?.first, let t = e.tags[6], t.count >= 2 else { continue }
                let start = min(t[0], text.count), end = min(start + min(t[1], text.count), text.count)
                var bytes = Array(text[start..<end])
                var basePtr = end
                for _ in 0..<fragCount {
                    guard fragPtr < frags.count else { break }
                    let fr = frags[fragPtr]
                    fragPtr += 1
                    let fragEnd = min(basePtr + max(fr.length, 0), text.count)
                    let at = safeInsertPosition(bytes, min(max(fr.insertPos - start, 0), bytes.count))
                    bytes.insert(contentsOf: text[basePtr..<fragEnd], at: at)
                    basePtr = fragEnd
                }
                parts.append(Part(bytes: bytes, start: start))
            }
        }
        if parts.isEmpty { parts = [Part(bytes: Array(text[flows[0]]), start: flows[0].lowerBound)] }

        func locate(_ pos: Int) -> (part: Int, local: Int)? {
            guard let i = parts.firstIndex(where: { pos >= $0.start && pos < $0.end }) else { return nil }
            return (i, pos - parts[i].start)
        }
        func locate(fid: Int, off: Int) -> (part: Int, local: Int)? {
            fid >= 0 && fid < frags.count && off >= 0 && off < 1 << 40 ? locate(frags[fid].insertPos + off) : nil
        }

        // Collect every link/TOC target so anchors can be inserted before decoding.
        var requests = [Set<Int>](repeating: [], count: parts.count)
        var linkTargets: [String: (part: Int, local: Int)] = [:]
        let posPattern = "kindle:pos:fid:(\(base32)+):off:(\(base32)+)"
        for p in parts {
            for m in HTML.matches(String(decoding: p.bytes, as: UTF8.self), posPattern, options: []) {
                guard let fid = m.groups[1].flatMap({ Int($0, radix: 32) }), let off = m.groups[2].flatMap({ Int($0, radix: 32) }),
                      let loc = locate(fid: fid, off: off) else { continue }
                linkTargets["\(fid):\(off)"] = loc
                requests[loc.part].insert(loc.local)
            }
        }
        var ncxRows: [(title: String, parent: Int?, loc: (part: Int, local: Int)?)] = []
        if let ncx = h.ncx, let index = try? readIndex(db, ncx, utf8: utf8) {
            for e in index.entries {
                var loc: (part: Int, local: Int)?
                if let pf = e.tags[6], pf.count >= 2 { loc = locate(fid: pf[0], off: pf[1]) }
                if loc == nil, let pos = e.tags[1]?.first { loc = locate(pos) }
                if let loc { requests[loc.part].insert(loc.local) }
                let title = index.string(e.tags[3]?.first) ?? ""
                ncxRows.append((title.trimmingCharacters(in: .whitespacesAndNewlines), e.tags[21]?.first, loc))
            }
        }
        var anchors: [[Int: String]] = []
        for i in parts.indices {
            anchors.append(insertAnchors(&parts[i].bytes, requests[i], prefix: "kp\(i)_", utf8: utf8))
        }

        var built = Built()
        func resolveEmbeds(_ s: String, prefix: String) -> String {
            HTML.replace(s, "kindle:embed:(\(base32){4})(\\?mime=[^\"'\\s)]*)?", options: []) { g in
                g[1].flatMap { Int($0, radix: 32) }.flatMap { resources[$0] }.map { prefix + $0 } ?? ""
            }
        }

        // Extra flows: SVG gets inlined where referenced, everything else is a stylesheet.
        var flowPaths: [Int: String] = [:]
        var inlineSVG: [Int: String] = [:]
        for (i, r) in flows.enumerated().dropFirst() where !r.isEmpty {
            let s = decodeText(Array(text[r]), utf8: utf8)
            if let svg = s.range(of: "<svg", options: .caseInsensitive) {
                inlineSVG[i] = resolveEmbeds(String(s[svg.lowerBound...]), prefix: "")
            } else {
                let css = s.replacingOccurrences(of: "<![CDATA[", with: "").replacingOccurrences(of: "]]>", with: "")
                let path = String(format: "styles/flow%04d.css", i)
                flowPaths[i] = path
                built.files.append(OutputFile(path: path, content: resolveEmbeds(css, prefix: "../")))
            }
        }

        var docs: [String] = []
        var names: [String] = []
        for (i, p) in parts.enumerated() {
            var s = decodeText(p.bytes, utf8: utf8)
            s = HTML.replace(s, "<[^<>]*kindle:flow:(\(base32){4})[^<>]*>", options: []) { g in
                g[1].flatMap { Int($0, radix: 32) }.flatMap { inlineSVG[$0] } ?? g[0] ?? ""
            }
            s = HTML.replace(s, "kindle:flow:(\(base32){4})(\\?mime=[^\"'\\s)]*)?", options: []) { g in
                g[1].flatMap { Int($0, radix: 32) }.flatMap { flowPaths[$0] } ?? ""
            }
            s = resolveEmbeds(s, prefix: "")
            s = HTML.replace(s, "\\s(?:aid|AID)\\s*=\\s*(?:\"[^\"]*\"|'[^']*')", options: []) { _ in "" }
            // Non-stylesheet links (e.g. rel="icon" to the original cover file) point at files that don't exist.
            s = HTML.replace(s, "<link\\b(?![^>]*stylesheet)[^>]*>") { _ in "" }
            let xhtml = HTML.numericEntities(HTML.finishDocument(s, xhtml: true))
            if HTML.isWellFormedXML(xhtml) {
                docs.append(xhtml)
                names.append(String(format: "part%04d.xhtml", i))
            } else {
                docs.append(HTML.finishDocument(HTML.expandSelfClosing(s), xhtml: false))
                names.append(String(format: "part%04d.html", i))
            }
        }

        func href(_ loc: (part: Int, local: Int)) -> String {
            names[loc.part] + (anchors[loc.part][loc.local].map { "#\($0)" } ?? "")
        }
        for (i, doc) in docs.enumerated() {
            let s = HTML.replace(doc, posPattern, options: []) { g in
                guard let fid = g[1].flatMap({ Int($0, radix: 32) }), let off = g[2].flatMap({ Int($0, radix: 32) }),
                      let loc = linkTargets["\(fid):\(off)"] else { return "#" }
                return href(loc)
            }
            built.files.append(OutputFile(path: names[i], content: s))
            built.spine.append((names[i], HTML.textWeight(s)))
        }

        let items = ncxRows.map { row in
            NCXItem(title: row.title, parent: row.parent,
                    target: row.loc.map { (spine: $0.part, fragment: anchors[$0.part][$0.local]) })
        }
        built.toc = buildTOC(items)
        if built.toc.isEmpty { built.toc = HTML.headingTOC(docs) }
        return built
    }

    /// Moves an insertion point that falls inside a tag to just after it.
    private static func safeInsertPosition(_ b: [UInt8], _ at: Int) -> Int {
        let lt = UInt8(ascii: "<"), gt = UInt8(ascii: ">")
        let lastLT = b[..<at].lastIndex(of: lt) ?? -1
        let lastGT = b[..<at].lastIndex(of: gt) ?? -1
        guard lastLT > lastGT, let next = b[at...].firstIndex(of: gt) else { return at }
        return next + 1
    }

    /// Gives the element at each local position an id (reusing an existing one) and returns position → id.
    private static func insertAnchors(_ bytes: inout [UInt8], _ positions: Set<Int>, prefix: String, utf8: Bool) -> [Int: String] {
        guard !positions.isEmpty, !bytes.isEmpty else { return [:] }
        var result: [Int: String] = [:]
        var inserts: [Int: (at: Int, id: String)] = [:]
        for p in positions {
            guard let t = targetTag(bytes, p) else { continue }
            if let planned = inserts[t] {
                result[p] = planned.id
            } else if let id = existingID(bytes, t, utf8: utf8) {
                result[p] = id
            } else {
                var nameEnd = t + 1
                while nameEnd < bytes.count, !" \t\r\n/>".utf8.contains(bytes[nameEnd]) { nameEnd += 1 }
                let id = "\(prefix)\(t)"
                inserts[t] = (nameEnd, id)
                result[p] = id
            }
        }
        guard !inserts.isEmpty else { return result }
        var out = [UInt8]()
        out.reserveCapacity(bytes.count + inserts.count * 24)
        var last = 0
        for ins in inserts.values.sorted(by: { $0.at < $1.at }) {
            out += bytes[last..<ins.at]
            out += Array(" id=\"\(ins.id)\"".utf8)
            last = ins.at
        }
        out += bytes[last...]
        bytes = out
        return result
    }

    /// Start of the element a position refers to: the tag at/containing it, else the nearest preceding start tag.
    private static func targetTag(_ b: [UInt8], _ pos: Int) -> Int? {
        let lt = UInt8(ascii: "<"), gt = UInt8(ascii: ">")
        var p = min(max(pos, 0), b.count - 1)
        var q = p
        while q < b.count, q - p < 256, [0x20, 0x09, 0x0A, 0x0D].contains(b[q]) { q += 1 }
        if q < b.count, b[q] == lt { p = q }
        var t: Int?
        if b[p] == lt {
            t = p
        } else {
            let nextGT = b[p...].firstIndex(of: gt), nextLT = b[p...].firstIndex(of: lt)
            if let nextGT, nextLT.map({ nextGT < $0 }) ?? true {
                t = b[...p].lastIndex(of: lt)
            } else {
                t = b[..<p].lastIndex(of: lt)
            }
        }
        var steps = 0
        while let s = t, steps < 4096 {
            steps += 1
            if s + 1 < b.count, ![UInt8(ascii: "/"), UInt8(ascii: "!"), UInt8(ascii: "?")].contains(b[s + 1]) {
                var e = s + 1
                while e < b.count, !" \t\r\n/>".utf8.contains(b[e]) { e += 1 }
                let name = String(decoding: b[(s + 1)..<e], as: UTF8.self).lowercased()
                return ["html", "head", "meta", "link", "title", "style", "script", "xml"].contains(name) ? nil : s
            }
            t = s > 0 ? b[..<s].lastIndex(of: lt) : nil
        }
        return nil
    }

    private static func existingID(_ b: [UInt8], _ t: Int, utf8: Bool) -> String? {
        guard let end = b[t...].prefix(8192).firstIndex(of: UInt8(ascii: ">")) else { return nil }
        let tag = decodeText(Array(b[t...end]), utf8: utf8)
        return HTML.firstMatch(tag, "\\sid\\s*=\\s*[\"']([^\"']+)[\"']", options: []).flatMap { $0.groups[1] }
    }
}
