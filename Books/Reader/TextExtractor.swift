import Foundation
import PDFKit
import SwiftUI

struct SearchResult: Identifiable, Hashable {
    let id = UUID()
    var locator: Locator
    var occurrence: Int
    var chapter: String
    /// The text the match is in, and the match's UTF-8 offsets there.
    var text: String
    var matchOffsets: Range<Int>

    static func == (a: SearchResult, b: SearchResult) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var snippet: AttributedString {
        let utf8 = text.utf8
        let lower = utf8.index(utf8.startIndex, offsetBy: min(matchOffsets.lowerBound, utf8.count))
        let upper = utf8.index(utf8.startIndex, offsetBy: min(matchOffsets.upperBound, utf8.count))
        let start = text.index(lower, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(upper, offsetBy: 80, limitedBy: text.endIndex) ?? text.endIndex
        var match = AttributedString(String(text[lower..<upper]))
        match.font = .body.bold()
        match.foregroundColor = .primary
        return AttributedString((start > text.startIndex ? "…" : "") + String(text[start..<lower]).collapsingWhitespaceKeepingEdges)
            + match
            + AttributedString(String(text[upper..<end]).collapsingWhitespaceKeepingEdges + (end < text.endIndex ? "…" : ""))
    }
}

/// Plain text of every spine item, for search and Claude's whole-book context.
enum TextExtractor {
    static func texts(for publication: Publication, bookID: String) -> [String] {
        switch publication.kind {
        case .comic: return publication.spine.map { _ in "" }
        case .pdf:
            let cache = BookLoader.cacheDirectory(for: publication.sourceURL, bookID: bookID).appendingPathComponent("text.json")
            if let data = try? Data(contentsOf: cache), let cached = try? JSONDecoder().decode([String].self, from: data) {
                return cached
            }
            let pages = pdfPages(publication.sourceURL)
            if !pages.isEmpty, let data = try? JSONEncoder().encode(pages) {
                try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: cache, options: .atomic)
            }
            return pages
        case .reflowable:
            return parallelMap(publication.spine.count) { i in
                guard let data = try? Data(contentsOf: publication.spine[i].url) else { return "" }
                let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
                return plainText(fromHTML: html)
            }
        }
    }

    /// Each worker opens its own document, so no `PDFDocument` crosses threads.
    private static func pdfPages(_ url: URL) -> [String] {
        guard let count = PDFDocument(url: url)?.pageCount, count > 0 else { return [] }
        let workers = min(ProcessInfo.processInfo.activeProcessorCount, count)
        let chunks = parallelMap(workers) { w -> [String] in
            let pages = (count * w / workers)..<(count * (w + 1) / workers)
            let doc = PDFDocument(url: url)
            return pages.map { p in
                autoreleasepool {
                    var text = doc?.page(at: p)?.string ?? ""
                    text.makeContiguousUTF8()
                    return text
                }
            }
        }
        return chunks.flatMap { $0 }
    }

    private static func parallelMap<T>(_ count: Int, _ transform: (Int) -> T) -> [T] {
        var results = [T?](repeating: nil, count: count)
        results.withUnsafeMutableBufferPointer { buffer in
            let slots = buffer
            DispatchQueue.concurrentPerform(iterations: count) { slots[$0] = transform($0) }
        }
        return results.map { $0! }
    }

    // MARK: HTML

    /// Approximates `document.body.textContent` so search occurrences line up with the web view.
    static func plainText(fromHTML html: String) -> String {
        var html = html
        return html.withUTF8 { source in
            let body = bytesAfterBodyTag(source)
            let withoutTags = strippingTags(strippingScriptsAndStyles(body))
            return withoutTags.withUnsafeBufferPointer(decodingEntities)
        }
    }

    private static func bytesAfterBodyTag(_ s: UnsafeBufferPointer<UInt8>) -> UnsafeBufferPointer<UInt8> {
        var i = 0
        while let open = s.firstIndex(of: UInt8(ascii: "<"), from: i) {
            if s.hasPrefixIgnoringCase("body", at: open + 1) {
                guard let close = s.firstIndex(of: UInt8(ascii: ">"), from: open + 5) else { return s }
                return UnsafeBufferPointer(rebasing: s[(close + 1)...])
            }
            i = open + 1
        }
        return s
    }

    private static func strippingScriptsAndStyles(_ s: UnsafeBufferPointer<UInt8>) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(s.count)
        var copied = 0
        var i = 0
        while let open = s.firstIndex(of: UInt8(ascii: "<"), from: i) {
            i = open + 1
            guard let tag = ["script", "style"].first(where: { s.hasPrefixIgnoringCase($0, at: open + 1) }),
                  let close = s.firstIndex(of: UInt8(ascii: ">"), from: open + 1 + tag.utf8.count),
                  let end = s.endOfClosingTag(tag, from: close + 1) else { continue }
            out.append(contentsOf: s[copied..<open])
            copied = end
            i = end
        }
        out.append(contentsOf: s[copied...])
        return out
    }

    /// Drops every `<…>` with at least one byte inside. A `<` with no later `>`, and an empty `<>`, stay as text.
    private static func strippingTags(_ source: [UInt8]) -> [UInt8] {
        source.withUnsafeBufferPointer { s in
            var out = [UInt8]()
            out.reserveCapacity(s.count)
            var i = 0
            while let open = s.firstIndex(of: UInt8(ascii: "<"), from: i) {
                guard let close = s.firstIndex(of: UInt8(ascii: ">"), from: open + 1) else { break }
                if close == open + 1 {
                    out.append(contentsOf: s[i..<close])
                    i = close
                } else {
                    out.append(contentsOf: s[i..<open])
                    i = close + 1
                }
            }
            out.append(contentsOf: s[i...])
            return out
        }
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "mdash": "—", "ndash": "–", "hellip": "…", "lsquo": "‘", "rsquo": "’",
        "ldquo": "“", "rdquo": "”", "shy": "\u{00AD}", "copy": "©",
    ]

    private static func decodingEntities(_ s: UnsafeBufferPointer<UInt8>) -> String {
        var out = [UInt8]()
        var copied = 0
        var i = 0
        while let amp = s.firstIndex(of: UInt8(ascii: "&"), from: i) {
            i = amp + 1
            let window = s[(amp + 1)..<min(amp + 12, s.count)]
            guard let semi = window.firstIndex(of: UInt8(ascii: ";")),
                  let replacement = decodedEntity(String(decoding: s[(amp + 1)..<semi], as: UTF8.self)) else { continue }
            if out.isEmpty { out.reserveCapacity(s.count) }
            out.append(contentsOf: s[copied..<amp])
            out.append(contentsOf: replacement.utf8)
            copied = semi + 1
            i = semi + 1
        }
        out.append(contentsOf: s[copied...])
        return String(decoding: out, as: UTF8.self)
    }

    private static func decodedEntity(_ entity: String) -> String? {
        if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
            return UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        if entity.hasPrefix("#") {
            return UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        return namedEntities[entity]
    }

    // MARK: Search

    /// `texts` lowercased, for repeated searches of the same book.
    static func lowercased(_ texts: [String]) -> [String] {
        parallelMap(texts.count) { texts[$0].lowercased() }
    }

    /// Matches literally on the lowercased text, as `Reader.find` does, so `occurrence` addresses the same match there.
    static func search(_ query: String, in texts: [String], lowered: [String]? = nil, publication: Publication, limit: Int = 500) -> [SearchResult] {
        let needle = Array(query.lowercased().utf8)
        guard !needle.isEmpty else { return [] }
        let lowered = lowered ?? lowercased(texts)
        var results: [SearchResult] = []
        for index in texts.indices {
            let offsets = matchOffsets(of: needle, in: lowered[index], limit: limit - results.count)
            guard !offsets.isEmpty else { continue }
            var text = texts[index]
            text.makeContiguousUTF8()
            let chapter = publication.kind == .pdf ? "Page \(index + 1)" : (publication.tocEntry(forSpineIndex: index)?.title ?? "")
            let length = max(1, text.count)
            let utf8 = text.utf8
            let progress = publication.progressCalculator(spineIndex: index)
            var previous = text.startIndex
            var distance = 0
            for (occurrence, offset) in offsets.enumerated() {
                let lower = utf8.index(utf8.startIndex, offsetBy: min(offset, utf8.count))
                distance += text.distance(from: previous, to: lower)
                previous = lower
                let progression = Double(distance) / Double(length)
                let locator = Locator(index: index, progression: progression, totalProgress: progress(progression))
                results.append(SearchResult(locator: locator, occurrence: occurrence, chapter: chapter,
                                            text: text, matchOffsets: offset..<(offset + needle.count)))
            }
            if results.count >= limit { return results }
        }
        return results
    }

    private static func matchOffsets(of needle: [UInt8], in haystack: String, limit: Int) -> [Int] {
        var haystack = haystack
        return haystack.withUTF8 { hay in
            guard let base = hay.baseAddress else { return [] }
            var offsets: [Int] = []
            var from = 0
            while offsets.count < limit, from + needle.count <= hay.count,
                  let hit = memmem(base + from, hay.count - from, needle, needle.count) {
                let offset = UnsafePointer(hit.assumingMemoryBound(to: UInt8.self)) - base
                offsets.append(offset)
                from = offset + needle.count
            }
            return offsets
        }
    }
}

private extension UnsafeBufferPointer<UInt8> {
    func firstIndex(of byte: UInt8, from start: Int) -> Int? {
        guard start < count, let base = baseAddress,
              let hit = memchr(base + start, Int32(byte), count - start) else { return nil }
        return UnsafePointer(hit.assumingMemoryBound(to: UInt8.self)) - base
    }

    /// `ascii` must be lowercase.
    func hasPrefixIgnoringCase(_ ascii: String, at start: Int) -> Bool {
        var i = start
        for expected in ascii.utf8 {
            guard i < count, self[i] | 0x20 == expected else { return false }
            i += 1
        }
        return true
    }

    /// The index just past the first case-insensitive `</tag>` at or after `start`.
    func endOfClosingTag(_ tag: String, from start: Int) -> Int? {
        var i = start
        while let open = firstIndex(of: UInt8(ascii: "<"), from: i) {
            let name = open + 2
            if name < count, self[open + 1] == UInt8(ascii: "/"), hasPrefixIgnoringCase(tag, at: name) {
                let close = name + tag.utf8.count
                if close < count, self[close] == UInt8(ascii: ">") { return close + 1 }
            }
            i = open + 1
        }
        return nil
    }
}

extension String {
    /// Runs of whitespace become one space.
    var collapsingWhitespaceKeepingEdges: String {
        var out = String.UnicodeScalarView()
        var inRun = false
        for scalar in unicodeScalars {
            if scalar.properties.isWhitespace {
                if !inRun { out.append(" ") }
                inRun = true
            } else {
                out.append(scalar)
                inRun = false
            }
        }
        return String(out)
    }
}
