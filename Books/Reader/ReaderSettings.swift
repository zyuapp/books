import AppKit
import Observation
import SwiftUI

enum ReaderTheme: String, Codable, CaseIterable, Identifiable {
    case auto, original, paper, sepia, calm, quiet, night, midnight

    var id: String { rawValue }

    var name: String {
        switch self {
        case .auto: "Auto"
        case .original: "White"
        case .paper: "Paper"
        case .sepia: "Sepia"
        case .calm: "Calm"
        case .quiet: "Quiet"
        case .night: "Night"
        case .midnight: "Midnight"
        }
    }

    /// Concrete theme for the current system appearance.
    func resolved(dark: Bool) -> ReaderTheme {
        self == .auto ? (dark ? .night : .paper) : self
    }

    var background: String {
        switch self {
        case .auto, .paper: "#FAF7F0"
        case .original: "#FFFFFF"
        case .sepia: "#F3E9D2"
        case .calm: "#E7EBE0"
        case .quiet: "#3B3B3E"
        case .night: "#1E1D1B"
        case .midnight: "#000000"
        }
    }

    var foreground: String {
        switch self {
        case .auto, .paper: "#26231F"
        case .original: "#1D1D1F"
        case .sepia: "#4F3D2B"
        case .calm: "#2C3529"
        case .quiet: "#D9D8DC"
        case .night: "#DAD5CC"
        case .midnight: "#A9A9AE"
        }
    }

    var secondary: String {
        switch self {
        case .quiet: "#9C9BA1"
        case .night: "#8E887D"
        case .midnight: "#6B6B70"
        default: "#8B847A"
        }
    }

    var accent: String {
        switch self {
        case .sepia: "#9A5B21"
        case .calm: "#3E6B48"
        case .quiet, .night, .midnight: "#E3A857"
        default: "#B0652B"
        }
    }

    var isDark: Bool { [.quiet, .night, .midnight].contains(self) }

    var backgroundColor: Color { Color(hex: background) }
    var foregroundColor: Color { Color(hex: foreground) }
    var secondaryColor: Color { Color(hex: secondary) }
}

struct ReaderFont: Identifiable, Hashable {
    let id: String
    let name: String
    let css: String

    static let all: [ReaderFont] = [
        ReaderFont(id: "publisher", name: "Original", css: ""),
        ReaderFont(id: "newyork", name: "New York", css: "ui-serif, 'New York', Georgia, serif"),
        ReaderFont(id: "charter", name: "Charter", css: "Charter, 'Bitstream Charter', Georgia, serif"),
        ReaderFont(id: "iowan", name: "Iowan", css: "'Iowan Old Style', Palatino, serif"),
        ReaderFont(id: "palatino", name: "Palatino", css: "Palatino, 'Palatino Linotype', serif"),
        ReaderFont(id: "baskerville", name: "Baskerville", css: "Baskerville, 'Libre Baskerville', serif"),
        ReaderFont(id: "athelas", name: "Athelas", css: "Athelas, Georgia, serif"),
        ReaderFont(id: "georgia", name: "Georgia", css: "Georgia, serif"),
        ReaderFont(id: "sf", name: "San Francisco", css: "-apple-system, system-ui, sans-serif"),
        ReaderFont(id: "avenir", name: "Avenir Next", css: "'Avenir Next', Avenir, sans-serif"),
        ReaderFont(id: "seravek", name: "Seravek", css: "Seravek, 'Gill Sans', sans-serif"),
    ]

    static func named(_ id: String) -> ReaderFont { all.first { $0.id == id } ?? all[1] }

    /// SwiftUI font for previews in the settings popover.
    func preview(size: CGFloat) -> Font {
        switch id {
        case "publisher", "newyork": .system(size: size, design: .serif)
        case "sf": .system(size: size)
        default:
            Font.custom(css.split(separator: ",").first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "' ")) } ?? "Georgia", size: size)
        }
    }
}

enum PageLayout: String, Codable, CaseIterable, Identifiable {
    case paginated, scroll
    var id: String { rawValue }
    var name: String { self == .paginated ? "Pages" : "Scroll" }
}

enum SpreadMode: String, Codable, CaseIterable, Identifiable {
    case auto, single, double
    var id: String { rawValue }
    var name: String {
        switch self {
        case .auto: "Auto"
        case .single: "Single"
        case .double: "Two Pages"
        }
    }
}

struct ReaderPreferences: Codable, Equatable {
    var theme: ReaderTheme = .auto
    var fontID = "newyork"
    var fontSize: Double = 19
    var lineHeight: Double = 1.55
    var margin: Double = 56
    var justify = true
    var hyphenate = true
    var layout: PageLayout = .paginated
    var spread: SpreadMode = .auto
    var pageTurnAnimation = true
    var dimPDFInDarkThemes = false
    var comicRightToLeft: Bool? = nil
}

/// App-wide reading preferences, persisted in UserDefaults.
@MainActor @Observable
final class ReaderSettings {
    static let shared = ReaderSettings()

    var prefs: ReaderPreferences {
        didSet {
            if let data = try? JSONEncoder().encode(prefs) { UserDefaults.standard.set(data, forKey: "readerPreferences") }
        }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: "readerPreferences"),
           let p = try? JSONDecoder().decode(ReaderPreferences.self, from: data) {
            prefs = p
        } else {
            prefs = ReaderPreferences()
        }
    }
}

extension Color {
    init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&value)
        self.init(.sRGB,
                  red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

extension NSColor {
    convenience init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&value)
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

extension HighlightColor {
    var color: Color {
        switch self {
        case .yellow: Color(hex: "#F7D154")
        case .green: Color(hex: "#8FD18B")
        case .blue: Color(hex: "#8BC3F2")
        case .pink: Color(hex: "#F49BB8")
        case .purple: Color(hex: "#C1A3F0")
        case .underline: Color(hex: "#E25B45")
        }
    }

    var nsColor: NSColor {
        switch self {
        case .yellow: NSColor(hex: "#F7D154")
        case .green: NSColor(hex: "#8FD18B")
        case .blue: NSColor(hex: "#8BC3F2")
        case .pink: NSColor(hex: "#F49BB8")
        case .purple: NSColor(hex: "#C1A3F0")
        case .underline: NSColor(hex: "#E25B45")
        }
    }
}
