import Foundation

/// Mobipocket / Kindle reader for DRM-free MOBI6, KF8 (AZW3) and combined MOBI6+KF8 files.
enum MOBIParser {
    /// Parses a DRM-free .mobi/.prc/.azw/.azw3 file and writes renderable XHTML chapters + images into `dir` (already exists, empty).
    static func parse(_ url: URL, into dir: URL) throws -> Publication {
        let data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) } catch {
            throw PublicationError.corrupt("the file couldn’t be read")
        }
        let db = try PalmDB([UInt8](data))
        let h0 = try Header(db, base: 0)
        guard h0.encryption == 0 else { throw PublicationError.drmProtected }

        var kf8: Header?
        var boundary: Int?
        if h0.hasMOBI, h0.version >= 8, h0.skel != nil {
            kf8 = h0
        } else if let b = h0.int(121), b > 0, b < db.count, BE.hasPrefix(db.record(b - 1), "BOUNDARY"),
                  let h = try? Header(db, base: b), h.hasMOBI, h.version >= 8 {
            guard h.encryption == 0 else { throw PublicationError.drmProtected }
            kf8 = h
            boundary = b - 1
        }
        let meta = [kf8, h0].compactMap { $0 }
        func first(_ type: Int) -> String? { meta.lazy.compactMap { $0.strings(type).first }.first }

        let fileTitle = url.deletingPathExtension().lastPathComponent
        let title = first(503) ?? meta.lazy.compactMap { $0.fullName?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
            ?? (db.name.isEmpty ? fileTitle : db.name.replacingOccurrences(of: "_", with: " "))
        let authors = meta.lazy.map { $0.strings(100) }.first { !$0.isEmpty } ?? []
        let language = first(524) ?? localeLanguage(h0.locale)

        var resources: [Int: String] = [:]
        // Combo files share the MOBI6 resource records (before the boundary) with the KF8 part.
        if let start = h0.firstResource ?? kf8?.firstResource {
            resources = try extractResources(db, range: start..<max(start, boundary ?? db.count), into: dir)
        }
        if resources.isEmpty, boundary != nil, let start = kf8?.firstResource {
            resources = try extractResources(db, range: start..<db.count, into: dir)
        }

        let built: Built
        if !h0.hasMOBI {
            built = try buildPlainText(db, h0, title: title)
        } else if let kf8 {
            do {
                built = try buildKF8(db, kf8, resources: resources)
            } catch where boundary != nil {
                built = try buildMOBI6(db, h0, resources: resources, title: title, language: language)
            }
        } else {
            built = try buildMOBI6(db, h0, resources: resources, title: title, language: language)
        }
        guard !built.spine.isEmpty else { throw PublicationError.corrupt("the book has no readable content") }

        let fm = FileManager.default
        for file in built.files {
            let target = dir.appendingPathComponent(file.path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.content.write(to: target, atomically: false, encoding: .utf8)
        }

        let coverPath = [201, 202].lazy.compactMap { type in
            meta.lazy.compactMap { $0.int(type) }.first.flatMap { resources[$0 + 1] }
        }.first { $0.hasPrefix("images/") }

        return Publication(
            kind: .reflowable,
            title: title,
            author: authors.isEmpty ? nil : authors.joined(separator: ", "),
            language: language,
            spine: built.spine.map { SpineItem(url: dir.appendingPathComponent($0.path), weight: $0.weight) },
            toc: built.toc,
            coverURL: coverPath.map { dir.appendingPathComponent($0) },
            rightToLeft: first(527)?.lowercased() == "rtl",
            rootDirectory: dir,
            sourceURL: url
        )
    }

    private static func localeLanguage(_ locale: Int) -> String? {
        let codes: [Int: String] = [
            1: "ar", 2: "bg", 3: "ca", 4: "zh", 5: "cs", 6: "da", 7: "de", 8: "el", 9: "en", 10: "es", 11: "fi", 12: "fr",
            13: "he", 14: "hu", 15: "is", 16: "it", 17: "ja", 18: "ko", 19: "nl", 20: "no", 21: "pl", 22: "pt", 24: "ro",
            25: "ru", 26: "hr", 27: "sk", 28: "sq", 29: "sv", 30: "th", 31: "tr", 32: "ur", 33: "id", 34: "uk", 35: "be",
            36: "sl", 37: "et", 38: "lv", 39: "lt", 41: "fa", 42: "vi", 43: "hy", 44: "az", 45: "eu", 47: "mk", 54: "af",
            55: "ka", 57: "hi", 62: "ms", 65: "sw", 73: "ta", 78: "mr",
        ]
        return codes[locale & 0xFF]
    }
}
