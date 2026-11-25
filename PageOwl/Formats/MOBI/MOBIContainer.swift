import Foundation

extension MOBIParser {
    static let nullIndex = 0xFFFF_FFFF

    /// Bounds-checked big-endian reads; every accessor returns nil when out of range.
    enum BE {
        static func u16(_ b: [UInt8], _ o: Int) -> Int? {
            guard o >= 0, o <= b.count - 2 else { return nil }
            return Int(b[o]) << 8 | Int(b[o + 1])
        }

        static func u32(_ b: [UInt8], _ o: Int) -> Int? {
            guard o >= 0, o <= b.count - 4 else { return nil }
            return Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3])
        }

        static func bytes(_ b: [UInt8], _ o: Int, _ n: Int) -> [UInt8]? {
            guard o >= 0, n >= 0, o <= b.count - n else { return nil }
            return Array(b[o..<o + n])
        }

        static func hasPrefix(_ b: [UInt8], _ s: String, at o: Int = 0) -> Bool {
            let p = Array(s.utf8)
            guard o >= 0, o <= b.count - p.count else { return false }
            return b[o..<o + p.count].elementsEqual(p)
        }
    }

    struct PalmDB {
        let data: [UInt8]
        let ranges: [Range<Int>]
        let name: String
        let type: String

        init(_ data: [UInt8]) throws {
            guard data.count >= 78, let n = BE.u16(data, 76), n > 0, data.count >= 78 + n * 8 else {
                throw PublicationError.corrupt("not a Mobipocket file")
            }
            let offsets = (0..<n).map { BE.u32(data, 78 + $0 * 8) ?? data.count }
            ranges = (0..<n).map { i in
                let start = min(offsets[i], data.count)
                let end = i + 1 < n ? min(max(offsets[i + 1], start), data.count) : data.count
                return start..<end
            }
            self.data = data
            name = String(decoding: data[0..<32].prefix { $0 != 0 }, as: UTF8.self)
            type = String(decoding: data[60..<68], as: UTF8.self)
        }

        var count: Int { ranges.count }

        func record(_ i: Int) -> [UInt8] { i >= 0 && i < ranges.count ? Array(data[ranges[i]]) : [] }
    }

    /// PalmDOC + MOBI + EXTH headers of the record-0 at `base` (0, or the KF8 record of a combo file).
    struct Header {
        let base: Int
        let compression: Int
        let textLength: Int
        let textRecordCount: Int
        let encryption: Int
        let hasMOBI: Bool
        let isUTF8: Bool
        let version: Int
        let fullName: String?
        let locale: Int
        let firstResource: Int?
        let huffRecord: Int?
        let huffCount: Int
        let extraFlags: Int
        let ncx: Int?
        let frag: Int?
        let skel: Int?
        let fdst: Int?
        let exth: [Int: [[UInt8]]]

        init(_ db: PalmDB, base: Int) throws {
            let r = db.record(base)
            guard r.count >= 16, let comp = BE.u16(r, 0) else { throw PublicationError.corrupt("missing book header") }
            self.base = base
            compression = comp
            textLength = BE.u32(r, 4) ?? 0
            textRecordCount = BE.u16(r, 8) ?? 0
            encryption = BE.u16(r, 12) ?? 0
            hasMOBI = BE.hasPrefix(r, "MOBI", at: 16)
            let headerLength = hasMOBI ? BE.u32(r, 20) ?? 0 : 0
            let limit = min(r.count, 16 + headerLength)
            func field(_ o: Int) -> Int? { o + 4 <= limit ? BE.u32(r, o) : nil }
            func index(_ o: Int) -> Int? {
                guard let v = field(o), v != MOBIParser.nullIndex, base + v < db.count else { return nil }
                return base + v
            }
            let utf8 = field(28) == 65001
            isUTF8 = utf8
            version = max(field(0x24) ?? 0, field(0x68) ?? 0)
            locale = field(0x5C) ?? 0
            if let off = field(0x54), let len = field(0x58), len > 0, let b = BE.bytes(r, off, min(len, 4096)) {
                fullName = MOBIParser.decodeText(b, utf8: utf8)
            } else {
                fullName = nil
            }
            firstResource = index(0x6C)
            huffRecord = comp == 17480 ? index(0x70) : nil
            huffCount = comp == 17480 ? field(0x74) ?? 0 : 0
            extraFlags = version >= 5 && headerLength >= 0xE4 ? BE.u16(r, 0xF2) ?? 0 : 0
            ncx = index(0xF4)
            let kf8 = version >= 8
            frag = kf8 ? index(0xF8) : nil
            skel = kf8 ? index(0xFC) : nil
            fdst = kf8 ? index(0xC0) : nil

            var exth: [Int: [[UInt8]]] = [:]
            if let flags = field(0x80), flags & 0x40 != 0 {
                let o = 16 + headerLength
                if BE.hasPrefix(r, "EXTH", at: o), let count = BE.u32(r, o + 8) {
                    var p = o + 12
                    for _ in 0..<min(count, 4096) {
                        guard let t = BE.u32(r, p), let l = BE.u32(r, p + 4), l >= 8,
                              let v = BE.bytes(r, p + 8, l - 8) else { break }
                        exth[t, default: []].append(v)
                        p += l
                    }
                }
            }
            self.exth = exth
        }

        func strings(_ type: Int) -> [String] {
            (exth[type] ?? []).map { MOBIParser.decodeText($0, utf8: isUTF8).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        func int(_ type: Int) -> Int? {
            guard let v = exth[type]?.first, v.count >= 1, v.count <= 4 else { return nil }
            return v.reduce(0) { $0 << 8 | Int($1) }
        }
    }

    // MARK: - Text

    static func decodeText(_ b: [UInt8], utf8: Bool) -> String {
        if utf8 { return String(decoding: b, as: UTF8.self) }
        var s = String.UnicodeScalarView()
        s.reserveCapacity(b.count)
        for c in b {
            if c >= 0x80, c <= 0x9F, let u = Unicode.Scalar(cp1252High[Int(c) - 0x80]) {
                s.append(u)
            } else {
                s.append(Unicode.Scalar(c))
            }
        }
        return String(s)
    }

    private static let cp1252High: [UInt32] = [
        0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F,
        0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178,
    ]

    /// Concatenated, decompressed text records with trailing entries removed.
    static func extractText(_ db: PalmDB, _ h: Header) throws -> [UInt8] {
        var huff: HuffDecoder?
        switch h.compression {
        case 1, 2: break
        case 17480:
            guard let first = h.huffRecord, h.huffCount > 0 else { throw PublicationError.corrupt("missing HUFF tables") }
            let cdics = (1..<max(1, min(h.huffCount, 1024))).map { db.record(first + $0) }
            huff = try HuffDecoder(huff: db.record(first), cdics: cdics)
        default:
            throw PublicationError.corrupt("unknown compression \(h.compression)")
        }
        var out = [UInt8]()
        out.reserveCapacity(min(h.textLength, 64 << 20))
        for i in 0..<h.textRecordCount {
            let index = h.base + 1 + i
            guard index < db.count else { break }
            let rec = db.record(index)
            let body = Array(rec[0..<(rec.count - trailingSize(rec, flags: h.extraFlags))])
            switch h.compression {
            case 1: out += body
            case 2: out += palmDocDecompress(body)
            default: if let huff { out += try huff.decompress(body) }
            }
            guard out.count < 512 << 20 else { throw PublicationError.corrupt("text too large") }
        }
        if h.textLength > 0, out.count > h.textLength { out.removeLast(out.count - h.textLength) }
        return out
    }

    static func trailingSize(_ r: [UInt8], flags: Int) -> Int {
        var size = 0
        var f = flags >> 1
        while f != 0 {
            if f & 1 != 0 {
                var p = r.count - size, shift = 0, value = 0
                while p > 0 {
                    let v = Int(r[p - 1])
                    value |= (v & 0x7F) << shift
                    shift += 7
                    p -= 1
                    if v & 0x80 != 0 || shift >= 28 { break }
                }
                size += value
                if size >= r.count { return r.count }
            }
            f >>= 1
        }
        if flags & 1 != 0, size < r.count {
            size += Int(r[r.count - size - 1] & 0x3) + 1
        }
        return min(size, r.count)
    }

    // MARK: - Resources

    static func imageExtension(_ b: [UInt8]) -> String? {
        guard b.count >= 8 else { return nil }
        if b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return "jpg" }
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return "png" }
        if BE.hasPrefix(b, "GIF8") { return "gif" }
        if BE.hasPrefix(b, "BM"), b.count > 26 { return "bmp" }
        return nil
    }

    /// Writes image and font records in `range` to `dir/images` / `dir/fonts`.
    /// Keys are the 1-based resource numbers used by `recindex` and `kindle:embed`.
    static func extractResources(_ db: PalmDB, range: Range<Int>, into dir: URL) throws -> [Int: String] {
        var paths: [Int: String] = [:]
        let fm = FileManager.default
        var made = Set<String>()
        func write(_ data: Data, _ folder: String, _ name: String) throws -> String {
            if !made.contains(folder) {
                try fm.createDirectory(at: dir.appendingPathComponent(folder, isDirectory: true), withIntermediateDirectories: true)
                made.insert(folder)
            }
            let rel = "\(folder)/\(name)"
            try data.write(to: dir.appendingPathComponent(rel))
            return rel
        }
        for i in range {
            let rec = db.record(i)
            let n = i - range.lowerBound + 1
            if let ext = imageExtension(rec) {
                paths[n] = try write(Data(rec), "images", String(format: "image%05d.%@", n, ext))
            } else if BE.hasPrefix(rec, "FONT"), let (font, ext) = decodeFont(rec) {
                paths[n] = try write(font, "fonts", String(format: "font%05d.%@", n, ext))
            }
        }
        return paths
    }

    private static func decodeFont(_ r: [UInt8]) -> (Data, String)? {
        guard let usize = BE.u32(r, 4), let flags = BE.u32(r, 8), let start = BE.u32(r, 12),
              let xorLen = BE.u32(r, 16), let xorStart = BE.u32(r, 20), start < r.count else { return nil }
        var font = Array(r[start...])
        if flags & 2 != 0, xorLen > 0, let key = BE.bytes(r, xorStart, xorLen) {
            for i in 0..<min(1040, font.count) { font[i] ^= key[i % xorLen] }
        }
        if flags & 1 != 0 {
            // zlib stream: skip the 2-byte header, inflate the raw deflate data.
            guard font.count > 2, let d = try? (Data(font[2...]) as NSData).decompressed(using: .zlib) as Data,
                  d.count == usize else { return nil }
            font = [UInt8](d)
        }
        if BE.hasPrefix(font, "OTTO") { return (Data(font), "otf") }
        if BE.hasPrefix(font, "true") || BE.hasPrefix(font, "ttcf") || font.starts(with: [0, 1, 0, 0]) { return (Data(font), "ttf") }
        return nil
    }
}
