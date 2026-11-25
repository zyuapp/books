import AppKit
import SwiftUI

/// A book cover: the extracted thumbnail, or a typeset cover generated from the title. A cover whose shape differs from
/// its slot fits inside it whole, resting on the slot's bottom edge so a row of covers shares a baseline.
struct CoverView: View {
    let bookID: String
    let title: String
    let author: String?
    var cornerRadius: CGFloat = 5
    var shadowOpacity: Double = 0
    var shadowRadius: CGFloat = 0
    var shadowY: CGFloat = 0
    @State private var library = LibraryStore.shared

    /// Covers this close to the slot's shape fill it; a sliver of cropping is invisible.
    private static let fillTolerance: CGFloat = 0.04

    var body: some View {
        GeometryReader { slot in
            let image = library.cover(bookID)
            let size = coverSize(image, in: slot.size)
            ZStack {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: size.width, height: size.height)
                        .clipped()
                } else {
                    GeneratedCover(title: title, author: author)
                }
                // Spine and page-edge shading.
                HStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(0.28), .white.opacity(0.10), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: 10)
                    Spacer()
                }
                LinearGradient(colors: [.white.opacity(0.10), .clear, .black.opacity(0.06)], startPoint: .top, endPoint: .bottom)
            }
            .frame(width: size.width, height: size.height)
            .clipShape(.rect(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
            .background {
                if shadowOpacity > 0 {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(.black)
                        .padding(1)
                        .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius, y: shadowY)
                }
            }
            .frame(width: slot.size.width, height: slot.size.height, alignment: .bottomLeading)
        }
    }

    private func coverSize(_ image: NSImage?, in slot: CGSize) -> CGSize {
        guard let image, image.size.width > 0, image.size.height > 0, slot.height > 0 else { return slot }
        let aspect = image.size.width / image.size.height, slotAspect = slot.width / slot.height
        if abs(aspect - slotAspect) / slotAspect <= Self.fillTolerance { return slot }
        return aspect > slotAspect
            ? CGSize(width: slot.width, height: slot.width / aspect)
            : CGSize(width: slot.height * aspect, height: slot.height)
    }
}

struct GeneratedCover: View {
    let title: String
    let author: String?

    private static let palettes: [(String, String, String)] = [
        ("#2F4858", "#1D2D38", "#E9D8A6"),
        ("#6B2D2D", "#3E1A1A", "#F2D7B6"),
        ("#2E4A3B", "#1B2E24", "#E8E1C8"),
        ("#3C3A6B", "#22214A", "#E4DDF7"),
        ("#7A5230", "#4A3019", "#F6E7CF"),
        ("#24476B", "#152B42", "#DCE8F4"),
        ("#5A3A5E", "#382239", "#F1DCE9"),
        ("#3F3F3F", "#202020", "#E9E2D0"),
        ("#8A6E2F", "#5A4519", "#FBF1D6"),
        ("#2C5F5D", "#183B3A", "#DDF0EC"),
    ]

    static func palette(for title: String) -> (String, String, String) {
        let hash = title.unicodeScalars.reduce(5381) { ($0 << 5) &+ $0 &+ Int($1.value) }
        return palettes[abs(hash) % palettes.count]
    }

    var body: some View {
        let palette = Self.palette(for: title)
        GeometryReader { geo in
            let w = geo.size.width
            ZStack {
                LinearGradient(colors: [Color(hex: palette.0), Color(hex: palette.1)], startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: w * 0.06) {
                    Rectangle().fill(Color(hex: palette.2).opacity(0.7)).frame(width: w * 0.22, height: max(1, w * 0.008))
                    Text(title)
                        .font(.system(size: max(9, w * 0.11), weight: .semibold, design: .serif))
                        .multilineTextAlignment(.center)
                        .lineLimit(5)
                        .minimumScaleFactor(0.6)
                        .foregroundStyle(Color(hex: palette.2))
                    if let author {
                        Text(author.uppercased())
                            .font(.system(size: max(6, w * 0.055), weight: .medium))
                            .tracking(w * 0.008)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Color(hex: palette.2).opacity(0.75))
                    }
                    Rectangle().fill(Color(hex: palette.2).opacity(0.7)).frame(width: w * 0.22, height: max(1, w * 0.008))
                }
                .padding(w * 0.12)
            }
        }
    }
}
