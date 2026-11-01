import Foundation

/// Extracts ZIP, RAR, 7z and TAR archives with the system `bsdtar` (libarchive).
enum Archive {
    static func extract(_ archive: URL, to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        process.arguments = ["-x", "-f", archive.path, "-C", dir.path]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "archive error"
            // bsdtar exits non-zero on some recoverable warnings; accept partial output.
            if (try? FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty) == false { return }
            throw PublicationError.corrupt(message)
        }
    }

    /// All regular files under `dir`, recursively, sorted with natural (Finder-like) ordering.
    static func files(in dir: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var result: [URL] = []
        for case let url as URL in e {
            if url.path.contains("__MACOSX") { continue }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                result.append(url)
            }
        }
        return result.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }
}

extension URL {
    var lowercaseExtension: String { pathExtension.lowercased() }

    /// Resolves `href` (may be percent-encoded, may contain a fragment) relative to this file's directory.
    func resolvingHref(_ href: String) -> (url: URL, fragment: String?) {
        var path = href
        var fragment: String?
        if let hash = href.firstIndex(of: "#") {
            fragment = String(href[href.index(after: hash)...])
            path = String(href[..<hash])
        }
        let decoded = path.removingPercentEncoding ?? path
        let base = deletingLastPathComponent()
        let url = decoded.isEmpty ? self : URL(fileURLWithPath: decoded, relativeTo: base).standardizedFileURL
        return (url, fragment?.isEmpty == true ? nil : fragment)
    }
}

extension String {
    var xmlEscaped: String {
        var s = self
        s = s.replacingOccurrences(of: "&", with: "&amp;")
        s = s.replacingOccurrences(of: "<", with: "&lt;")
        s = s.replacingOccurrences(of: ">", with: "&gt;")
        s = s.replacingOccurrences(of: "\"", with: "&quot;")
        return s
    }

    var collapsingWhitespace: String {
        split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// "Topic 1. It’s Your LifeIt’s Your Life" → "Topic 1. It’s Your Life": some PDF outlines store a title twice.
    var droppingRepeatedTail: String {
        let chars = Array(self)
        var length = chars.count / 2
        while length >= 6 {
            let tail = chars[(chars.count - length)...]
            let before = chars[(chars.count - 2 * length)..<(chars.count - length)]
            if tail.elementsEqual(before) { return String(chars[..<(chars.count - length)]) }
            length -= 1
        }
        return self
    }

    /// Replaces `&#160;`, `&#x2014;` and the common named entities that stray into PDF outlines.
    var decodingHTMLEntities: String {
        guard contains("&") else { return self }
        let named: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{A0}",
                                       "mdash": "—", "ndash": "–", "hellip": "…", "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“"]
        var out = ""
        var rest = Substring(self)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            rest = rest[amp...]
            guard let semi = rest.firstIndex(of: ";"), rest.distance(from: rest.startIndex, to: semi) <= 10 else {
                out += "&"; rest = rest.dropFirst(); continue
            }
            let body = rest[rest.index(after: rest.startIndex)..<semi]
            let decoded: String?
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                decoded = UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map(String.init)
            } else if body.hasPrefix("#") {
                decoded = UInt32(body.dropFirst()).flatMap(Unicode.Scalar.init).map(String.init)
            } else {
                decoded = named[String(body)]
            }
            if let decoded {
                out += decoded
                rest = rest[rest.index(after: semi)...]
            } else {
                out += "&"; rest = rest.dropFirst()
            }
        }
        return out + rest
    }
}

enum HTMLTemplate {
    static func document(title: String, body: String, css: String = "", lang: String? = nil) -> String {
        let langAttr = lang.map { " lang=\"\($0.xmlEscaped)\"" } ?? ""
        return """
        <!DOCTYPE html>
        <html\(langAttr)><head><meta charset="utf-8"><title>\(title.xmlEscaped)</title>
        <style>\(css)</style></head>
        <body>\(body)</body></html>
        """
    }
}
