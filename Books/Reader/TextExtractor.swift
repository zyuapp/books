import Foundation
import PDFKit
import SwiftUI

/// Plain text of every spine item, for search and Claude's whole-book context.
enum TextExtractor {
    static func texts(for publication: Publication) -> [String] {
        switch publication.kind {
        case .comic: return publication.spine.map { _ in "" }
        case .pdf:
            guard let doc = PDFDocument(url: publication.sourceURL) else { return [] }
            return (0..<doc.pageCount).map { doc.page(at: $0)?.string ?? "" }
        case .reflowable:
            return publication.spine.map { item in
                guard let data = try? Data(contentsOf: item.url) else { return "" }
                let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
                return plainText(fromHTML: html)
            }
        }
    }

    /// Approximates `document.body.textContent` so search occurrences line up with the web view.
    static func plainText(fromHTML html: String) -> String {
        var s = html
        if let body = s.range(of: "<body[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            s = String(s[body.upperBound...])
        }
        s = s.replacingOccurrences(of: "<(script|style)[^>]*>[\\s\\S]*?</\\1>", with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return decodeEntities(s)
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        let named: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
                                       "mdash": "—", "ndash": "–", "hellip": "…", "lsquo": "‘", "rsquo": "’",
                                       "ldquo": "“", "rdquo": "”", "shy": "\u{00AD}", "copy": "©"]
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let entity = String(s[s.index(after: i)..<semi])
                var replacement: String?
                if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                    replacement = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else if entity.hasPrefix("#") {
                    replacement = UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else {
                    replacement = named[entity]
                }
                if let replacement {
                    out += replacement
                    i = s.index(after: semi)
                    continue
                }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }

    static func search(_ query: String, in texts: [String], publication: Publication, limit: Int = 500) -> [SearchResult] {
        var results: [SearchResult] = []
        for (index, text) in texts.enumerated() {
            let lower = text.lowercased()
            var from = lower.startIndex
            var occurrence = 0
            let chapter = publication.kind == .pdf ? "Page \(index + 1)" : (publication.tocEntry(forSpineIndex: index)?.title ?? "")
            while let r = lower.range(of: query.lowercased(), range: from..<lower.endIndex) {
                let start = text.index(r.lowerBound, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex
                let end = text.index(r.upperBound, offsetBy: 80, limitedBy: text.endIndex) ?? text.endIndex
                var snippet = AttributedString((start > text.startIndex ? "…" : "") + String(text[start..<r.lowerBound]).collapsingWhitespaceKeepingEdges)
                var match = AttributedString(String(text[r]))
                match.font = .body.bold()
                match.foregroundColor = .primary
                snippet += match
                snippet += AttributedString(String(text[r.upperBound..<end]).collapsingWhitespaceKeepingEdges + (end < text.endIndex ? "…" : ""))
                let distance = text.distance(from: text.startIndex, to: r.lowerBound)
                let progression = Double(distance) / Double(max(1, text.count))
                let locator = Locator(index: index, progression: progression,
                                      totalProgress: publication.progress(spineIndex: index, progression: progression))
                results.append(SearchResult(locator: locator, occurrence: occurrence, snippet: snippet, chapter: chapter))
                occurrence += 1
                from = r.upperBound
                if results.count >= limit { return results }
            }
        }
        return results
    }
}

extension String {
    var collapsingWhitespaceKeepingEdges: String {
        replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}
