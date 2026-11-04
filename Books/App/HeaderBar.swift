import AppKit
import SwiftUI

/// The strip across the top of the main window, over the hidden title bar. The library and the reader each fill it
/// with their own controls at the same places, so switching screens changes what it holds and never where anything sits.
struct HeaderBar<Leading: View, Trailing: View>: View {
    static var height: CGFloat { 52 }
    /// Room for the window buttons.
    static var leadingInset: CGFloat { 88 }

    var title: String
    var subtitle: String?
    var serif = false
    var titleColor: Color?
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        ZStack {
            VStack(spacing: 1) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: serif ? .serif : .default))
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.callout).foregroundStyle(.primary.opacity(0.62)).lineLimit(1)
                }
            }
            .foregroundStyle(titleColor ?? .primary)
            .frame(maxWidth: 440)
            .padding(.horizontal, 240)

            HStack(spacing: 0) {
                leading
                Spacer(minLength: 12)
                trailing
            }
            .padding(.leading, Self.leadingInset)
            .padding(.trailing, 14)
        }
        .controlSize(.large)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: Self.titleBarDoubleClick)
    }

    /// What the covered title bar would do.
    private static func titleBarDoubleClick() {
        guard let window = NSApp.keyWindow, !window.styleMask.contains(.fullScreen) else { return }
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "None": break
        case "Minimize": window.miniaturize(nil)
        default: window.zoom(nil)
        }
    }
}

/// A glass search field for the header.
struct HeaderSearchField: View {
    var prompt: String
    @Binding var text: String
    var focus: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused(focus)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear Search")
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 230, height: 30)
        .glassSurface(in: .capsule)
    }
}

/// One icon in a `HeaderButtonGroup`.
struct HeaderButton: View {
    let symbol: String
    let label: String
    var tooltip: String?
    var active = false
    var color: Color?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .fontWeight(.medium)
                .foregroundStyle(color ?? (active ? Color.brand : Color.primary))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 34, height: 28)
                .background(active ? Color.brand.opacity(0.16) : Color.primary.opacity(hovering ? 0.08 : 0), in: .capsule)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .tooltip(tooltip ?? label)
        .accessibilityLabel(label)
    }
}

/// Header icons sharing one capsule.
struct HeaderButtonGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 2) { content }
            .padding(2)
            .glassSurface(in: .capsule)
    }
}
