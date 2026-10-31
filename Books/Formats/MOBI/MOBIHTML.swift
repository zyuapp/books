import Foundation

extension MOBIParser {
    /// Regex-based markup helpers. Patterns are literals; an invalid one leaves the input unchanged.
    enum HTML {
        static func regex(_ pattern: String, _ options: NSRegularExpression.Options) -> NSRegularExpression? {
            try? NSRegularExpression(pattern: pattern, options: options)
        }

        struct Match {
            let range: NSRange
            let groups: [String?]
        }

        static func matches(_ s: String, _ pattern: String, options: NSRegularExpression.Options = [.caseInsensitive]) -> [Match] {
            guard let re = regex(pattern, options) else { return [] }
            let ns = s as NSString
            return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
                Match(range: m.range, groups: (0..<m.numberOfRanges).map {
                    let r = m.range(at: $0)
                    return r.location == NSNotFound ? nil : ns.substring(with: r)
                })
            }
        }

        static func firstMatch(_ s: String, _ pattern: String, options: NSRegularExpression.Options = [.caseInsensitive]) -> Match? {
            guard let re = regex(pattern, options) else { return nil }
            let ns = s as NSString
            guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
            return Match(range: m.range, groups: (0..<m.numberOfRanges).map {
                let r = m.range(at: $0)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            })
        }

        static func replace(_ s: String, _ pattern: String, options: NSRegularExpression.Options = [.caseInsensitive],
                            with transform: ([String?]) -> String) -> String {
            let ms = matches(s, pattern, options: options)
            guard !ms.isEmpty else { return s }
            let ns = s as NSString
            var out = ""
            out.reserveCapacity(ns.length + 64)
            var last = 0
            for m in ms {
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                out += transform(m.groups)
                last = NSMaxRange(m.range)
            }
            out += ns.substring(from: last)
            return out
        }

        static func split(_ s: String, _ pattern: String) -> [String] {
            let ns = s as NSString
            var parts: [String] = []
            var last = 0
            for m in matches(s, pattern) {
                parts.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
                last = NSMaxRange(m.range)
            }
            parts.append(ns.substring(from: last))
            return parts
        }

        static func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }

        /// Visible text of a markup fragment, whitespace-collapsed.
        static func plainText(_ html: String) -> String {
            let noTags = replace(html, "<[^>]*>", options: []) { _ in " " }
            return decodeEntities(noTags).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }

        /// UTF-8 byte count of the text outside tags (used as spine weight).
        static func textWeight(_ html: String) -> Int {
            var inTag = false, n = 0
            for b in html.utf8 {
                if b == UInt8(ascii: "<") { inTag = true } else if b == UInt8(ascii: ">") { inTag = false } else if !inTag { n += 1 }
            }
            return n
        }

        static func decodeEntities(_ s: String) -> String {
            guard s.contains("&") else { return s }
            return replace(s, "&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[A-Za-z][A-Za-z0-9]{1,31});", options: []) { g in
                guard let name = g[1], let cp = codePoint(name), let u = Unicode.Scalar(UInt32(cp)) else { return g[0] ?? "" }
                return String(Character(u))
            }
        }

        /// Rewrites named entities XML doesn't predefine as numeric references.
        static func numericEntities(_ s: String) -> String {
            guard s.contains("&") else { return s }
            return replace(s, "&([A-Za-z][A-Za-z0-9]{1,31});", options: []) { g in
                guard let name = g[1], !["amp", "lt", "gt", "quot", "apos"].contains(name), let cp = codePoint(name) else { return g[0] ?? "" }
                return "&#\(cp);"
            }
        }

        private static func codePoint(_ name: String) -> Int? {
            if name.hasPrefix("#x") || name.hasPrefix("#X") { return Int(name.dropFirst(2), radix: 16).flatMap(valid) }
            if name.hasPrefix("#") { return Int(name.dropFirst()).flatMap(valid) }
            if let v = entities[name] { return v }
            // Capitalized Latin-1 letters sit 0x20 below their lowercase forms (É = é - 0x20).
            if let first = name.first, first.isUppercase, let v = entities[name.prefix(1).lowercased() + name.dropFirst()],
               (0xE0...0xFE).contains(v), v != 0xF7 { return v - 0x20 }
            return nil
        }

        private static func valid(_ cp: Int) -> Int? {
            (cp == 0x9 || cp == 0xA || cp == 0xD || (0x20...0xD7FF).contains(cp) || (0xE000...0xFFFD).contains(cp)
                || (0x10000...0x10FFFF).contains(cp)) ? cp : nil
        }

        private static let entities: [String: Int] = [
            "amp": 38, "lt": 60, "gt": 62, "quot": 34, "apos": 39, "nbsp": 160, "iexcl": 161, "cent": 162, "pound": 163,
            "curren": 164, "yen": 165, "brvbar": 166, "sect": 167, "uml": 168, "copy": 169, "ordf": 170, "laquo": 171,
            "not": 172, "shy": 173, "reg": 174, "macr": 175, "deg": 176, "plusmn": 177, "sup2": 178, "sup3": 179,
            "acute": 180, "micro": 181, "para": 182, "middot": 183, "cedil": 184, "sup1": 185, "ordm": 186, "raquo": 187,
            "frac14": 188, "frac12": 189, "frac34": 190, "iquest": 191, "times": 215, "divide": 247, "szlig": 223,
            "agrave": 224, "aacute": 225, "acirc": 226, "atilde": 227, "auml": 228, "aring": 229, "aelig": 230,
            "ccedil": 231, "egrave": 232, "eacute": 233, "ecirc": 234, "euml": 235, "igrave": 236, "iacute": 237,
            "icirc": 238, "iuml": 239, "eth": 240, "ntilde": 241, "ograve": 242, "oacute": 243, "ocirc": 244,
            "otilde": 245, "ouml": 246, "oslash": 248, "ugrave": 249, "uacute": 250, "ucirc": 251, "uuml": 252,
            "yacute": 253, "thorn": 254, "yuml": 255, "OElig": 338, "oelig": 339, "Scaron": 352, "scaron": 353,
            "Yuml": 376, "fnof": 402, "circ": 710, "tilde": 732, "ensp": 8194, "emsp": 8195, "thinsp": 8201,
            "zwnj": 8204, "zwj": 8205, "lrm": 8206, "rlm": 8207, "ndash": 8211, "mdash": 8212, "lsquo": 8216,
            "rsquo": 8217, "sbquo": 8218, "ldquo": 8220, "rdquo": 8221, "bdquo": 8222, "dagger": 8224, "Dagger": 8225,
            "bull": 8226, "hellip": 8230, "permil": 8240, "prime": 8242, "Prime": 8243, "lsaquo": 8249, "rsaquo": 8250,
            "oline": 8254, "frasl": 8260, "euro": 8364, "trade": 8482, "larr": 8592, "uarr": 8593, "rarr": 8594,
            "darr": 8595, "harr": 8596, "minus": 8722, "infin": 8734, "ne": 8800, "le": 8804, "ge": 8805,
        ]

        static func isWellFormedXML(_ s: String) -> Bool {
            let parser = XMLParser(data: Data(s.utf8))
            parser.shouldResolveExternalEntities = false
            return parser.parse()
        }

        private static let voidElements: Set = [
            "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr",
        ]

        /// `<div/>` means an unclosed `<div>` to an HTML parser; expand non-void self-closing tags.
        static func expandSelfClosing(_ s: String) -> String {
            replace(s, "<([A-Za-z][A-Za-z0-9:_-]*)(\\s[^<>]*?)?/>") { g in
                let name = g[1] ?? "", attrs = g[2] ?? ""
                return voidElements.contains(name.lowercased()) ? "<\(name)\(attrs)>" : "<\(name)\(attrs)></\(name)>"
            }
        }

        /// Replaces any declared encoding with UTF-8 and makes sure the document has `<html>`/`<head>`.
        static func finishDocument(_ s: String, xhtml: Bool) -> String {
            var s = replace(s, "<\\?xml[^>]*\\?>") { _ in "" }
            s = replace(s, "<meta\\b[^>]*charset[^>]*>") { _ in "" }
            let meta = xhtml ? "<meta charset=\"utf-8\"/>" : "<meta charset=\"utf-8\">"
            let ns = s as NSString
            if let head = firstMatch(s, "<head\\b[^>]*>") {
                s = ns.replacingCharacters(in: NSRange(location: NSMaxRange(head.range), length: 0), with: meta)
            } else if let html = firstMatch(s, "<html\\b[^>]*>") {
                s = ns.replacingCharacters(in: NSRange(location: NSMaxRange(html.range), length: 0), with: "<head>\(meta)</head>")
            } else {
                s = "<html><head>\(meta)</head><body>\(s)</body></html>"
            }
            if xhtml {
                if let html = firstMatch(s, "<html\\b[^>]*>"), html.groups[0]?.contains("xmlns=") == false {
                    s = (s as NSString).replacingCharacters(in: NSRange(location: html.range.location + 5, length: 0),
                                                            with: " xmlns=\"http://www.w3.org/1999/xhtml\"")
                }
                return "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n" + s.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return s.lowercased().hasPrefix("<!doctype") ? s : "<!DOCTYPE html>\n" + s
        }

        /// One entry per document, titled by its first heading (or opening text).
        static func headingTOC(_ docs: [String]) -> [TOCEntry] {
            docs.enumerated().compactMap { i, doc in
                let body = firstMatch(doc, "<body\\b[^>]*>([\\s\\S]*)", options: [.caseInsensitive]).flatMap { $0.groups[1] } ?? doc
                var title = firstMatch(body, "<h[1-6]\\b[^>]*>([\\s\\S]*?)</h[1-6]\\s*>").flatMap { $0.groups[1] }.map(plainText) ?? ""
                if title.isEmpty {
                    let text = plainText(String(body.prefix(4000)))
                    guard !text.isEmpty else { return nil }
                    title = text.count > 60 ? String(text.prefix(60)) + "…" : text
                } else if title.count > 120 {
                    title = String(title.prefix(120)) + "…"
                }
                return TOCEntry(title: title, spineIndex: i)
            }
        }
    }
}
