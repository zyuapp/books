import AppKit
import SwiftUI

extension Color {
    /// The app's one accent, used for selection, progress and primary actions.
    static let brand = Color(hex: "#C96442")
}

/// A segmented control drawn in the app's accent; the system one always follows the system accent.
struct PillPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary.opacity(0.65)))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .background(selected ? AnyShapeStyle(Color.brand) : AnyShapeStyle(.clear), in: .capsule)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(.primary.opacity(0.07), in: .capsule)
    }
}

/// How far through a book the reader is.
struct ReadingProgressBar: View {
    let value: Double
    var height: CGFloat = 4

    var body: some View {
        Capsule()
            .fill(.primary.opacity(0.1))
            .overlay(alignment: .leading) {
                GeometryReader { track in
                    Capsule().fill(Color.brand).frame(width: track.size.width * min(1, max(0, value)))
                }
            }
            .frame(height: height)
            .accessibilityElement()
            .accessibilityValue("\(Int((value * 100).rounded())) percent")
    }
}

/// A message filling an empty list or screen.
struct EmptyStateView: View {
    let symbol: String
    let title: String
    let detail: String
    var large = false
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: large ? 14 : 10) {
            Image(systemName: symbol)
                .font(.system(size: large ? 30 : 20, weight: .regular))
                .foregroundStyle(Color.brand)
                .frame(width: large ? 72 : 48, height: large ? 72 : 48)
                .background(Color.brand.opacity(0.1), in: .circle)
            Text(title).font(.system(large ? .title : .title3, design: .serif).weight(.semibold))
            Text(detail).font(large ? .body : .callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle).font(.headline).padding(.horizontal, 6)
                }
                .glassProminentButtonStyle()
                .tint(Color.brand)
                .controlSize(.large)
                .padding(.top, 6)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

extension View {
    /// A floating reader panel: opaque and raised above the page, so its edges read against anything behind it.
    func readerPanelSurface(_ theme: ReaderTheme, cornerRadius: CGFloat = 26) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        return background {
            shape.fill(theme.isDark ? Color.white.opacity(0.07) : Color.white.opacity(0.55))
                .background(theme.backgroundColor, in: shape)
                .shadow(color: .black.opacity(theme.isDark ? 0.5 : 0.18), radius: 22, y: 8)
        }
        .overlay(shape.strokeBorder(.primary.opacity(theme.isDark ? 0.16 : 0.1), lineWidth: 0.5))
    }

    /// Fades scrolling content into the edges of its container.
    func verticalEdgeFade(_ length: CGFloat = 14) -> some View {
        mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: length)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 44)
                // Clear of the panel's rounded corners.
                Color.clear.frame(height: 8)
            }
        }
    }
}

extension NSImage {
    /// True for a page with no visible content, which makes a poor cover.
    var isNearlyBlank: Bool {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return true }
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
        context.interpolationQuality = .medium
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        return (pixels.max() ?? 0) - (pixels.min() ?? 0) < 6
    }
}

extension String {
    /// The title without a subtitle or a trailing parenthetical such as a download source.
    var mainTitle: String {
        var title = Substring(self)
        if let colon = title.range(of: ": ") { title = title[..<colon.lowerBound] }
        if let parenthesis = title.range(of: " ("), parenthesis.lowerBound > title.startIndex { title = title[..<parenthesis.lowerBound] }
        return title.trimmingCharacters(in: .whitespaces)
    }
}
