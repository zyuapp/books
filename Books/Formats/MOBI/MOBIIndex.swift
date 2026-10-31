import Foundation

extension MOBIParser {
    struct IndexEntry {
        let name: String
        let tags: [Int: [Int]]
    }

    /// A parsed INDX table (SKEL, FRAG, NCX…) plus its CNCX string records.
    struct MOBIIndex {
        var entries: [IndexEntry] = []
        var cncx: [[UInt8]] = []
        var utf8: Bool

        func string(_ offset: Int?) -> String? {
            guard let offset, offset >= 0 else { return nil }
            let rec = offset >> 16, pos = offset & 0xFFFF
            guard rec < cncx.count else { return nil }
            let (len, used) = decint(cncx[rec], pos)
            guard used > 0, let b = BE.bytes(cncx[rec], pos + used, len) else { return nil }
            return decodeText(b, utf8: utf8)
        }
    }

    /// Forward variable-width integer; the final byte has its high bit set.
    static func decint(_ b: [UInt8], _ start: Int) -> (value: Int, used: Int) {
        guard start >= 0 else { return (0, 0) }
        var v = 0, i = start
        while i < b.count, i - start < 9 {
            let c = b[i]
            i += 1
            v = v << 7 | Int(c & 0x7F)
            if c & 0x80 != 0 { break }
        }
        return (v, i - start)
    }

    private struct TagDef {
        let tag: Int, valuesPerEntry: Int, mask: Int, endFlag: Int
    }

    static func readIndex(_ db: PalmDB, _ idx: Int, utf8: Bool) throws -> MOBIIndex {
        let hdr = db.record(idx)
        guard BE.hasPrefix(hdr, "INDX"), let hlen = BE.u32(hdr, 4), let count = BE.u32(hdr, 24) else {
            throw PublicationError.corrupt("invalid index header")
        }
        var tagx = hlen
        if !BE.hasPrefix(hdr, "TAGX", at: tagx) {
            guard let found = (0..<max(0, hdr.count - 4)).first(where: { BE.hasPrefix(hdr, "TAGX", at: $0) }) else {
                throw PublicationError.corrupt("missing TAGX section")
            }
            tagx = found
        }
        let tagxLen = BE.u32(hdr, tagx + 4) ?? 0
        let controlCount = BE.u32(hdr, tagx + 8) ?? 0
        var defs: [TagDef] = []
        var o = tagx + 12
        while o + 4 <= min(tagx + tagxLen, hdr.count) {
            defs.append(TagDef(tag: Int(hdr[o]), valuesPerEntry: Int(hdr[o + 1]), mask: Int(hdr[o + 2]), endFlag: Int(hdr[o + 3])))
            o += 4
        }

        // Optional ORDT table that remaps ident bytes to code points.
        var ordt: [Int]?
        if let ocnt = BE.u32(hdr, 0xA4), let entries = BE.u32(hdr, 0xA8), let op2 = BE.u32(hdr, 0xB0),
           ocnt != 0 || entries > 0, entries < 65536, BE.hasPrefix(hdr, "ORDT", at: op2) {
            ordt = (0..<entries).compactMap { BE.u16(hdr, op2 + 4 + $0 * 2) }
        }

        var index = MOBIIndex(utf8: utf8)
        guard count < 65536 else { throw PublicationError.corrupt("index too large") }
        let ncncx = BE.u32(hdr, 52) ?? 0
        if ncncx < 4096 {
            index.cncx = (0..<ncncx).map { db.record(idx + count + 1 + $0) }
        }
        for i in (idx + 1)..<(idx + 1 + count) where i < db.count {
            let r = db.record(i)
            guard BE.hasPrefix(r, "INDX"), let idxt = BE.u32(r, 20), let n = BE.u32(r, 24), n <= r.count / 2 else { continue }
            var starts = (0..<n).compactMap { BE.u16(r, idxt + 4 + $0 * 2) }
            starts.append(idxt)
            for j in 0..<(starts.count - 1) {
                let s = starts[j], e = starts[j + 1]
                guard s < e, e <= r.count else { continue }
                let len = Int(r[s])
                guard s + 1 + len <= e else { continue }
                let ident = Array(r[(s + 1)..<(s + 1 + len)])
                let name: String
                if let ordt {
                    name = String(String.UnicodeScalarView(ident.compactMap {
                        Unicode.Scalar(UInt32(Int($0) < ordt.count ? ordt[Int($0)] : Int($0)))
                    }))
                } else {
                    name = decodeText(ident, utf8: utf8)
                }
                let tags = parseTags(Array(r[(s + 1 + len)..<e]), controlCount: controlCount, defs: defs)
                index.entries.append(IndexEntry(name: name, tags: tags))
            }
        }
        return index
    }

    private static func parseTags(_ data: [UInt8], controlCount: Int, defs: [TagDef]) -> [Int: [Int]] {
        guard controlCount <= data.count else { return [:] }
        var p = controlCount
        var controlIndex = 0
        var pending: [(tag: Int, count: Int?, bytes: Int?, perEntry: Int)] = []
        for d in defs {
            if d.endFlag == 1 {
                controlIndex += 1
                continue
            }
            guard controlIndex < controlCount else { break }
            guard d.mask != 0 else { continue }
            var value = Int(data[controlIndex]) & d.mask
            guard value != 0 else { continue }
            if value == d.mask {
                if d.mask.nonzeroBitCount > 1 {
                    let (v, used) = decint(data, p)
                    p += used
                    pending.append((d.tag, nil, v, d.valuesPerEntry))
                } else {
                    pending.append((d.tag, 1, nil, d.valuesPerEntry))
                }
            } else {
                var mask = d.mask
                while mask & 1 == 0 {
                    mask >>= 1
                    value >>= 1
                }
                pending.append((d.tag, value, nil, d.valuesPerEntry))
            }
        }
        var tags: [Int: [Int]] = [:]
        for t in pending {
            var values: [Int] = []
            if let count = t.count {
                for _ in 0..<(min(count, 4096) * t.perEntry) {
                    let (v, used) = decint(data, p)
                    guard used > 0 else { break }
                    p += used
                    values.append(v)
                }
            } else if let total = t.bytes {
                var consumed = 0
                while consumed < total {
                    let (v, used) = decint(data, p)
                    guard used > 0 else { break }
                    p += used
                    consumed += used
                    values.append(v)
                }
            }
            tags[t.tag] = values
        }
        return tags
    }

    /// A TOC row read from an NCX index, before tree assembly.
    struct NCXItem {
        var title: String
        var parent: Int?
        var target: (spine: Int, fragment: String?)?
    }

    /// Builds the TOC tree from NCX parent links; entries without a target inherit their first child's.
    static func buildTOC(_ items: [NCXItem]) -> [TOCEntry] {
        var children = [[Int]](repeating: [], count: items.count)
        var roots: [Int] = []
        for (i, item) in items.enumerated() {
            if let p = item.parent, p >= 0, p < i { children[p].append(i) } else { roots.append(i) }
        }
        func make(_ i: Int, depth: Int) -> TOCEntry? {
            let kids = depth < 32 ? children[i].compactMap { make($0, depth: depth + 1) } : []
            let title = items[i].title.isEmpty ? "Untitled" : items[i].title
            if let t = items[i].target {
                return TOCEntry(title: title, spineIndex: t.spine, fragment: t.fragment, children: kids)
            }
            guard let first = kids.first else { return nil }
            return TOCEntry(title: title, spineIndex: first.spineIndex, fragment: first.fragment, children: kids)
        }
        return roots.compactMap { make($0, depth: 0) }
    }
}
