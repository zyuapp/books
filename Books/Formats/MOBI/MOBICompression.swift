import Foundation

extension MOBIParser {
    static func palmDocDecompress(_ src: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(src.count * 2)
        var i = 0
        let n = src.count
        while i < n {
            let c = src[i]
            i += 1
            switch c {
            case 1...8:
                let end = min(i + Int(c), n)
                out += src[i..<end]
                i = end
            case 0x80...0xBF:
                guard i < n else { return out }
                let pair = (Int(c) << 8 | Int(src[i])) & 0x3FFF
                i += 1
                let distance = pair >> 3
                guard distance > 0, distance <= out.count else { continue }
                var from = out.count - distance
                for _ in 0..<((pair & 7) + 3) {
                    out.append(out[from])
                    from += 1
                }
            case 0xC0...0xFF:
                out.append(0x20)
                out.append(c ^ 0x80)
            default:
                out.append(c)
            }
        }
        return out
    }

    /// Mobipocket HUFF/CDIC decompressor.
    final class HuffDecoder {
        private var dict1: [(length: Int, terminal: Bool, max: UInt64)] = []
        private var minCode = [UInt64](repeating: 0, count: 33)
        private var maxCode = [UInt64](repeating: 0, count: 33)
        /// Phrase table; `expanded` phrases are final, others are themselves compressed. nil while expanding (cycle guard).
        private var phrases: [(bytes: [UInt8], expanded: Bool)?] = []

        init(huff: [UInt8], cdics: [[UInt8]]) throws {
            let bad = PublicationError.corrupt("invalid HUFF/CDIC tables")
            guard BE.hasPrefix(huff, "HUFF"), BE.u32(huff, 4) == 0x18,
                  let off1 = BE.u32(huff, 8), let off2 = BE.u32(huff, 12) else { throw bad }
            for i in 0..<256 {
                guard let v = BE.u32(huff, off1 + i * 4) else { throw bad }
                let length = v & 0x1F
                guard length != 0 else { throw bad }
                let maxValue = ((UInt64(v >> 8) + 1) << UInt64(32 - length)) - 1
                dict1.append((length, v & 0x80 != 0, maxValue))
            }
            for length in 1...32 {
                guard let lo = BE.u32(huff, off2 + (length - 1) * 8), let hi = BE.u32(huff, off2 + (length - 1) * 8 + 4) else { throw bad }
                minCode[length] = UInt64(lo) << UInt64(32 - length)
                maxCode[length] = ((UInt64(hi) + 1) << UInt64(32 - length)) - 1
            }
            maxCode[0] = (1 << 32) - 1
            for cdic in cdics {
                guard BE.hasPrefix(cdic, "CDIC"), BE.u32(cdic, 4) == 0x10,
                      let total = BE.u32(cdic, 8), let bits = BE.u32(cdic, 12), bits < 32 else { throw bad }
                let n = min(1 << bits, total - phrases.count)
                guard n > 0 else { continue }
                for j in 0..<n {
                    guard let off = BE.u16(cdic, 16 + j * 2), let blen = BE.u16(cdic, 16 + off),
                          let bytes = BE.bytes(cdic, 18 + off, blen & 0x7FFF) else { throw bad }
                    phrases.append((bytes, blen & 0x8000 != 0))
                }
            }
        }

        func decompress(_ data: [UInt8]) throws -> [UInt8] { try unpack(data, depth: 0) }

        private func unpack(_ data: [UInt8], depth: Int) throws -> [UInt8] {
            guard depth < 32 else { throw PublicationError.corrupt("HUFF recursion too deep") }
            func word(_ pos: Int) -> UInt64 {
                var x: UInt64 = 0
                for k in 0..<8 { x = x << 8 | UInt64(pos + k < data.count ? data[pos + k] : 0) }
                return x
            }
            var bitsLeft = data.count * 8
            var pos = 0
            var x = word(0)
            var n = 32
            var out = [UInt8]()
            while true {
                if n <= 0 {
                    pos += 4
                    x = word(pos)
                    n += 32
                }
                let code = (x >> UInt64(n)) & 0xFFFF_FFFF
                var (length, terminal, maxValue) = dict1[Int(code >> 24)]
                if !terminal {
                    while length < 32, code < minCode[length] { length += 1 }
                    maxValue = maxCode[length]
                }
                n -= length
                bitsLeft -= length
                if bitsLeft < 0 { break }
                let r = Int(truncatingIfNeeded: (maxValue &- code) >> UInt64(32 - length))
                guard r >= 0, r < phrases.count, let phrase = phrases[r] else {
                    throw PublicationError.corrupt("invalid HUFF code")
                }
                guard out.count < 1 << 22 else { throw PublicationError.corrupt("HUFF output too large") }
                if phrase.expanded {
                    out += phrase.bytes
                } else {
                    phrases[r] = nil
                    let expanded = try unpack(phrase.bytes, depth: depth + 1)
                    phrases[r] = (expanded, true)
                    out += expanded
                }
            }
            return out
        }
    }
}
