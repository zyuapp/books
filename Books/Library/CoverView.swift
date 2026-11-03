import CoreImage
import ImageIO
import SwiftUI

/// A book cover: the extracted thumbnail, or a typeset cover generated from the title.
struct CoverView: View {
    let bookID: String
    let title: String
    let author: String?
    var cornerRadius: CGFloat = 5
    @State private var library = LibraryStore.shared

    var body: some View {
        ZStack {
            if let image = library.cover(bookID) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
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
        .clipShape(.rect(cornerRadius: cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
    }
}

/// A soft colour wash taken from a book's cover. It's a small pre-blurred bitmap, which costs nothing to composite
/// compared with a live blur re-rendered every frame.
struct CoverWash: View {
    let bookID: String
    let title: String
    @State private var library = LibraryStore.shared
    @State private var wash: NSImage?

    var body: some View {
        ZStack {
            let colors = GeneratedCover.palette(for: title)
            LinearGradient(colors: [Color(hex: colors.0), Color(hex: colors.1)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let wash {
                Image(nsImage: wash)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            }
        }
        .task(id: "\(bookID)-\(library.coverVersion)") {
            let file = library.coverFile(bookID)
            wash = await Task.detached(priority: .utility) { Self.render(file) }.value
        }
    }

    private nonisolated static func render(_ file: URL) -> NSImage? {
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 48] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let input = CIImage(cgImage: thumbnail)
        let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: 6).cropped(to: input.extent)
        guard let output = CIContext().createCGImage(blurred, from: input.extent) else { return nil }
        return NSImage(cgImage: output, size: NSSize(width: output.width, height: output.height))
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
