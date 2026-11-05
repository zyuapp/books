import AppKit
import SwiftUI

struct SidePanel: View {
    static let width: CGFloat = 344
    static let edgeInset: CGFloat = 12
    /// Clears the window edge, including what glass draws outside the panel's frame.
    static var closedOffset: CGFloat { width + edgeInset + 30 }

    let model: ReaderModel
    @State private var lastPanel = ReaderPanel.contents
    @Environment(\.colorScheme) private var colorScheme

    /// Keeps showing the last panel while sliding out.
    private var shown: ReaderPanel { model.panel ?? lastPanel }

    private enum Segment: Hashable { case contents, highlights, bookmarks, search }

    private var segment: Segment {
        switch shown {
        case .contents: .contents
        case .notes: model.notesTab == 0 ? .highlights : .bookmarks
        case .search: .search
        }
    }

    private func select(_ segment: Segment) {
        switch segment {
        case .contents: model.panel = .contents
        case .highlights: model.notesTab = 0; model.panel = .notes
        case .bookmarks: model.notesTab = 1; model.panel = .notes
        case .search: model.panel = .search
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PillPicker(selection: Binding(get: { segment }, set: select),
                       options: [(.contents, "Contents"), (.highlights, "Highlights"), (.bookmarks, "Bookmarks"), (.search, "Search")])
                .padding(12)

            switch shown {
            case .contents: ContentsList(model: model)
            case .notes: NotesList(model: model)
            case .search: SearchPanel(model: model)
            }
        }
        .transaction { $0.animation = nil }
        .frame(width: Self.width)
        .glassSurface(in: .rect(cornerRadius: 26),
                      tint: ReaderSettings.shared.prefs.theme.resolved(dark: colorScheme == .dark).backgroundColor.opacity(0.6))
        .glassShadow(radius: 30, y: 10)
        .readerOverlay()
        .onChange(of: model.panel) { _, panel in
            if let panel { lastPanel = panel }
        }
    }
}

// MARK: Contents

private struct ContentsList: View {
    let model: ReaderModel
    @State private var rows: [Row] = []

    var body: some View {
        let current = model.publication?.tocEntry(forSpineIndex: model.location.index)?.id
        BookHeader(model: model).padding(.horizontal, 10).padding(.bottom, 4)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(rows) { row in
                        Button { model.go(to: row.entry) } label: {
                            HStack(alignment: .firstTextBaseline) {
                                Text(row.entry.title)
                                    .font(.system(size: row.depth == 0 ? 13.5 : 12.5).weight(row.entry.id == current ? .semibold : .regular))
                                    .foregroundStyle(row.entry.id == current ? Color.brand : .primary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 8)
                                if model.publication?.kind != .reflowable {
                                    Text("\(row.entry.spineIndex + 1)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.leading, CGFloat(row.depth) * 14)
                            .padding(.vertical, 7)
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(row.entry.id == current ? Color.brand.opacity(0.12) : .clear, in: .rect(cornerRadius: 10))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(row.entry.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 12)
                .padding(.bottom, 56)
            }
            .softScrollEdges(.all)
            .verticalEdgeFade(22)
            .onChange(of: model.publication == nil, initial: true) {
                rows = flatten(model.publication?.toc ?? [])
            }
            // Positions the list ahead of time while it's hidden, so opening doesn't have to.
            .onChange(of: current, initial: true) { _, id in
                if model.panel != .contents { center(id, proxy) }
            }
            .onChange(of: model.panel) { _, panel in
                if panel == .contents { center(current, proxy) }
            }
        }
    }

    private func center(_ id: UUID?, _ proxy: ScrollViewProxy) {
        guard let id else { return }
        withTransaction(Transaction(animation: nil)) { proxy.scrollTo(id, anchor: .center) }
    }

    struct Row: Identifiable { let entry: TOCEntry; let depth: Int; var id: UUID { entry.id } }

    private func flatten(_ entries: [TOCEntry], depth: Int = 0) -> [Row] {
        entries.flatMap { [Row(entry: $0, depth: depth)] + flatten($0.children, depth: depth + 1) }
    }
}

private struct BookHeader: View {
    let model: ReaderModel

    var body: some View {
        HStack(spacing: 12) {
            CoverView(bookID: model.book.id, title: model.title, author: model.publication?.author)
                .frame(width: 46, height: 68)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.title).font(.system(.title3, design: .serif).weight(.semibold)).lineLimit(2)
                if let author = model.publication?.author ?? model.state.author {
                    Text(author).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Text("\(Int((model.location.totalProgress * 100).rounded()))% read")
                    .font(.callout.weight(.medium)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 6)
    }
}

// MARK: Notes

private struct NotesList: View {
    let model: ReaderModel

    var body: some View {
        let highlights = model.state.liveHighlights.sorted { ($0.locator.totalProgress, $0.range?.start ?? 0) < ($1.locator.totalProgress, $1.range?.start ?? 0) }
        let bookmarks = model.state.liveBookmarks.sorted { $0.locator.totalProgress < $1.locator.totalProgress }
        let showsHighlights = model.notesTab == 0
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text(showsHighlights ? count(highlights.count, "highlight") : count(bookmarks.count, "bookmark"))
                    .font(.callout.weight(.medium)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Menu {
                    Button("Copy All as Markdown") { exportMarkdown() }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .tooltip("Export")
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 4)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if showsHighlights {
                        if highlights.isEmpty { empty("No highlights yet", "Select text to highlight it or add a note.") }
                        ForEach(Array(highlights.enumerated()), id: \.element.id) { i, h in
                            if i == 0 || highlights[i - 1].locator.label != h.locator.label, let chapter = h.locator.label {
                                Text(chapter)
                                    .font(.callout.weight(.semibold)).lineLimit(1)
                                    .padding(.top, i == 0 ? 6 : 16).padding(.bottom, 2)
                            }
                            HighlightRow(model: model, highlight: h)
                            Divider().opacity(0.6)
                        }
                    } else {
                        if bookmarks.isEmpty { empty("No bookmarks yet", "Press ⌘D to bookmark the current page.") }
                        ForEach(bookmarks) { b in
                            Button { model.jump(to: b.locator) } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: "bookmark.fill").foregroundStyle(Color(hex: "#E25B45"))
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(b.snippet).font(.custom("Charter", size: 14)).lineLimit(3).multilineTextAlignment(.leading)
                                        Text(ReaderModel.describe(b.locator, publication: model.publication))
                                            .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                                        Text(b.created.formatted(date: .abbreviated, time: .omitted))
                                            .font(.callout).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu { Button("Delete Bookmark", role: .destructive) { model.deleteBookmark(b.id) } }
                            Divider().opacity(0.6)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 56)
            }
            .softScrollEdges(.all)
            .verticalEdgeFade()
        }
    }

    private func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    private func empty(_ title: String, _ detail: String) -> some View {
        EmptyStateView(symbol: model.notesTab == 0 ? "highlighter" : "bookmark", title: title, detail: detail)
            .padding(.top, 20)
    }

    private func exportMarkdown() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.notesMarkdown(), forType: .string)
    }
}

private struct HighlightRow: View {
    let model: ReaderModel
    let highlight: Highlight

    var body: some View {
        Button { model.jump(to: highlight.locator) } label: {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(highlight.color.color.gradient).frame(width: 4)
                VStack(alignment: .leading, spacing: 6) {
                    let note = highlight.note.flatMap { $0.isEmpty ? nil : $0 }
                    Text(highlight.text)
                        .font(.custom("Charter", size: 14))
                        .lineLimit(5)
                        .multilineTextAlignment(.leading)
                    if let note {
                        Text(note)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("\(Int((highlight.locator.totalProgress * 100).rounded()))%")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Edit Note…") { model.noteEditor = highlight }
            Menu("Color") {
                ForEach(HighlightColor.allCases, id: \.self) { c in
                    Button(c.rawValue.capitalized) { model.updateHighlight(highlight.id) { $0.color = c } }
                }
            }
            Button("Copy Text") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(highlight.text, forType: .string)
            }
            Button("Ask Claude About This") {
                model.claudeDraft = ClaudeRequestSeed(passage: highlight.text, action: nil, locator: highlight.locator)
                model.showClaude = true
            }
            Divider()
            Button("Delete Highlight", role: .destructive) { model.deleteHighlight(highlight.id) }
        }
    }
}

// MARK: Search

private struct SearchPanel: View {
    @Bindable var model: ReaderModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search in book", text: $model.searchQuery)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { model.search(model.searchQuery) }
                if model.isSearching { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .glassSurface(in: .capsule)
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            .onChange(of: model.searchQuery) { _, q in model.search(q) }

            if model.publication?.kind == .comic {
                Text("Comics don’t contain searchable text.").font(.callout).foregroundStyle(.secondary).padding(.top, 30)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !model.searchResults.isEmpty {
                            Text("\(model.searchResults.count)\(model.searchResults.count >= 500 ? "+" : "") results")
                                .font(.callout.weight(.medium)).foregroundStyle(.secondary)
                                .padding(.horizontal, 4).padding(.bottom, 6)
                        }
                        ForEach(Array(model.searchResults.enumerated()), id: \.element.id) { i, r in
                            if i == 0 || model.searchResults[i - 1].chapter != r.chapter, !r.chapter.isEmpty {
                                Text(r.chapter)
                                    .font(.callout.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                                    .padding(.horizontal, 4).padding(.top, i == 0 ? 4 : 16).padding(.bottom, 4)
                            }
                            Button { model.reveal(r) } label: {
                                Text(r.snippet).font(.custom("Charter", size: 14)).foregroundStyle(.primary.opacity(0.85)).lineLimit(3)
                                    .multilineTextAlignment(.leading)
                                    .padding(.horizontal, 4).padding(.vertical, 8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider().opacity(0.5)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .padding(.bottom, 56)
                }
                .softScrollEdges(.all)
                .verticalEdgeFade()
            }
        }
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onChange(of: model.panel) { _, panel in focused = panel == .search }
    }
}

// MARK: Settings

struct ReaderSettingsPopover: View {
    let kind: PublicationKind
    var reader: ReaderModel?
    @State private var settings = ReaderSettings.shared

    var body: some View {
        @Bindable var s = settings
        VStack(alignment: .leading, spacing: 16) {
            ThemeGrid()
            Divider().opacity(0.6)

            if kind == .reflowable {
                HStack(spacing: 10) {
                    Button { s.prefs.fontSize = max(12, s.prefs.fontSize - 1) } label: {
                        Text("A").font(.system(size: 13, design: .serif)).frame(maxWidth: .infinity, minHeight: 26)
                            .background(.primary.opacity(0.07), in: .capsule).contentShape(Capsule())
                    }
                    Text("\(Int(s.prefs.fontSize)) pt").font(.body.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
                    Button { s.prefs.fontSize = min(40, s.prefs.fontSize + 1) } label: {
                        Text("A").font(.system(size: 21, design: .serif)).frame(maxWidth: .infinity, minHeight: 26)
                            .background(.primary.opacity(0.07), in: .capsule).contentShape(Capsule())
                    }
                }
                .buttonStyle(.plain)

                row("Font") {
                    Menu {
                        Picker("Font", selection: $s.prefs.fontID) {
                            ForEach(ReaderFont.all) { f in
                                Text(f.name).font(f.preview(size: 13)).tag(f.id)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } label: {
                        HStack {
                            Text(ReaderFont.named(s.prefs.fontID).name)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: 26)
                        .background(.primary.opacity(0.07), in: .capsule)
                        .contentShape(Capsule())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .accessibilityLabel("Font")
                }
                row("Spacing") {
                    slider("Line Spacing", value: $s.prefs.lineHeight, range: 1.1...2.2, readout: String(format: "%.2f×", s.prefs.lineHeight))
                }
                row("Margins") {
                    slider("Margins", value: $s.prefs.margin, range: 16...140, readout: "\(Int(s.prefs.margin)) pt")
                }
                switchRow("Justify", isOn: $s.prefs.justify)
                switchRow("Hyphenate", isOn: $s.prefs.hyphenate)
                Divider().opacity(0.6)
            }

            if kind == .pdf, let reader {
                HStack(spacing: 10) {
                    Button { reader.engine?.zoom(by: -1) } label: {
                        Image(systemName: "minus.magnifyingglass").frame(maxWidth: .infinity, minHeight: 26)
                            .background(.primary.opacity(0.07), in: .capsule).contentShape(Capsule())
                    }
                    .help("Zoom Out (⌘−)")
                    Button { reader.engine?.zoom(by: 0) } label: {
                        Text(reader.zoomPercent.map { "\($0)%" } ?? "Fit").font(.callout.monospacedDigit()).frame(maxWidth: .infinity, minHeight: 26)
                            .background(.primary.opacity(0.07), in: .capsule).contentShape(Capsule())
                    }
                    .help("Fit to Window (⌘0)")
                    Button { reader.engine?.zoom(by: 1) } label: {
                        Image(systemName: "plus.magnifyingglass").frame(maxWidth: .infinity, minHeight: 26)
                            .background(.primary.opacity(0.07), in: .capsule).contentShape(Capsule())
                    }
                    .help("Zoom In (⌘+)")
                }
                .buttonStyle(.plain)
            }

            if kind != .comic {
                row("Layout") {
                    PillPicker(selection: $s.prefs.layout, options: PageLayout.allCases.map { ($0, $0.name) })
                }
            }
            row("Pages") {
                PillPicker(selection: $s.prefs.spread, options: SpreadMode.allCases.map { ($0, $0.name) })
            }

            if kind == .pdf {
                switchRow("Invert pages in dark themes", isOn: $s.prefs.dimPDFInDarkThemes)
            }
            if kind == .comic {
                switchRow("Right-to-left (manga)", isOn: Binding(
                    get: { s.prefs.comicRightToLeft ?? false },
                    set: { s.prefs.comicRightToLeft = $0 }
                ))
            }
        }
        .padding(18)
        .frame(width: 360)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(label).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, readout: String) -> some View {
        HStack(spacing: 8) {
            Slider(value: value, in: range).accessibilityLabel(title).controlSize(.small).tint(Color.brand)
            Text(readout).font(.body.monospacedDigit()).foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
        }
    }

    private func switchRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small).tint(Color.brand)
        }
    }
}

struct ThemeGrid: View {
    @State private var settings = ReaderSettings.shared

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 10) {
            ForEach(ReaderTheme.allCases) { theme in
                let resolved = theme.resolved(dark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
                Button { settings.prefs.theme = theme } label: {
                    VStack(spacing: 5) {
                        ZStack {
                            if theme == .auto {
                                HStack(spacing: 0) {
                                    Color(hex: ReaderTheme.paper.background)
                                    Color(hex: ReaderTheme.night.background)
                                }
                            } else {
                                resolved.backgroundColor
                            }
                            Text("Aa")
                                .font(.system(size: 15, weight: .medium, design: .serif))
                                .foregroundStyle(theme == .auto ? Color.white : resolved.foregroundColor)
                                .blendMode(theme == .auto ? .difference : .normal)
                        }
                        .compositingGroup()
                        .frame(height: 40)
                        .clipShape(.rect(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(settings.prefs.theme == theme ? Color.brand : .primary.opacity(0.25),
                                              lineWidth: settings.prefs.theme == theme ? 2.5 : 1)
                        }
                        Text(theme.name).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}
