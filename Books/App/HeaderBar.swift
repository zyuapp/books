import AppKit
import SwiftUI

/// The strip across the top of the main window, over the hidden title bar. The library and the reader each fill it
/// with their own controls at the same places, so switching screens changes what it holds and never where anything sits.
struct HeaderBar<Leading: View, Trailing: View>: View {
    static var height: CGFloat { 52 }
    /// Room for the window buttons.
    static var leadingInset: CGFloat { 78 }

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
                    .font(serif ? .system(.headline, design: .serif) : .headline)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .foregroundStyle(titleColor ?? .primary)
            .frame(maxWidth: 420)
            .padding(.horizontal, 300)

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
