import AppKit
import SwiftUI

struct SidePanel: View {
    let model: ReaderModel
    let panel: ReaderPanel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: Binding(get: { model.panel ?? .contents }, set: { model.panel = $0 })) {
                Text("Contents").tag(ReaderPanel.contents)
                Text("Notes").tag(ReaderPanel.notes)
                Text("Search").tag(ReaderPanel.search)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(14)

            switch panel {
            case .contents: ContentsList(model: model)
            case .notes: NotesList(model: model)
            case .search: SearchPanel(model: model)
            }
        }
        .frame(width: 330)
        .glassEffect(.regular.tint(ReaderSettings.shared.prefs.theme.resolved(dark: colorScheme == .dark).backgroundColor.opacity(0.6)),
                     in: .rect(cornerRadius: 26))
        .readerOverlay()
        .shadow(color: .black.opacity(0.12), radius: 30, y: 10)
    }
}

// MARK: Contents

private struct ContentsList: View {
    let model: ReaderModel

    var body: some View {
        let toc = model.publication?.toc ?? []
        let current = model.publication?.tocEntry(forSpineIndex: model.location.index)?.id
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    BookHeader(model: model).padding(.bottom, 10)
                    ForEach(flatten(toc)) { row in
                        Button { model.go(to: row.entry) } label: {
                            HStack(alignment: .firstTextBaseline) {
                                Text(row.entry.title)
                                    .font(.system(size: row.depth == 0 ? 13.5 : 12.5, weight: row.entry.id == current ? .semibold : .regular, design: .serif))
                                    .foregroundStyle(row.entry.id == current ? Color.accentColor : .primary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 8)
                                if model.publication?.kind != .reflowable {
                                    Text("\(row.entry.spineIndex + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.leading, CGFloat(row.depth) * 14)
                            .padding(.vertical, 7)
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(row.entry.id == current ? Color.accentColor.opacity(0.12) : .clear, in: .rect(cornerRadius: 10))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(row.entry.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 14)
            }
            .scrollEdgeEffectStyle(.soft, for: .all)
            .onAppear { if let current { proxy.scrollTo(current, anchor: .center) } }
        }
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
                Text(model.title).font(.system(size: 14, weight: .semibold, design: .serif)).lineLimit(2)
                if let author = model.publication?.author ?? model.state.author {
                    Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text("\(Int((model.location.totalProgress * 100).rounded()))% read")
                    .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 6)
    }
}

// MARK: Notes

private struct NotesList: View {
    let model: ReaderModel
    @State private var tab = 0

    var body: some View {
        let highlights = model.state.liveHighlights.sorted { ($0.locator.totalProgress, $0.range?.start ?? 0) < ($1.locator.totalProgress, $1.range?.start ?? 0) }
        let bookmarks = model.state.liveBookmarks.sorted { $0.locator.totalProgress < $1.locator.totalProgress }
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $tab) {
                    Text("Highlights \(highlights.count)").tag(0)
                    Text("Bookmarks \(bookmarks.count)").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                Menu {
                    Button("Copy All as Markdown") { exportMarkdown(highlights, bookmarks) }
                } label: { Image(systemName: "square.and.arrow.up") }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if tab == 0 {
                        if highlights.isEmpty { empty("No highlights yet", "Select text to highlight it or add a note.") }
                        ForEach(highlights) { h in HighlightRow(model: model, highlight: h) }
                    } else {
                        if bookmarks.isEmpty { empty("No bookmarks yet", "Press ⌘D to bookmark the current page.") }
                        ForEach(bookmarks) { b in
                            Button { model.jump(to: b.locator) } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: "bookmark.fill").foregroundStyle(Color(hex: "#E25B45"))
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(b.snippet).font(.system(size: 13, design: .serif)).lineLimit(3).multilineTextAlignment(.leading)
                                        Text("\(ReaderModel.describe(b.locator, publication: model.publication)) · \(b.created.formatted(date: .abbreviated, time: .omitted))")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(12)
                                .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 14))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu { Button("Delete Bookmark", role: .destructive) { model.deleteBookmark(b.id) } }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
            .scrollEdgeEffectStyle(.soft, for: .all)
        }
    }

    private func empty(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private func exportMarkdown(_ highlights: [Highlight], _ bookmarks: [Bookmark]) {
        var md = "# \(model.title)\n"
        if let a = model.publication?.author { md += "*\(a)*\n" }
        for h in highlights {
            md += "\n> \(h.text.replacingOccurrences(of: "\n", with: "\n> "))\n"
            if let n = h.note { md += "\n\(n)\n" }
            md += "\n— \(ReaderModel.describe(h.locator, publication: model.publication))\n"
        }
        if !bookmarks.isEmpty {
            md += "\n## Bookmarks\n"
            for b in bookmarks { md += "- \(b.snippet) (\(ReaderModel.describe(b.locator, publication: model.publication)))\n" }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(md, forType: .string)
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
                    Text(highlight.text)
                        .font(.system(size: 13, design: .serif))
                        .lineLimit(5)
                        .multilineTextAlignment(.leading)
                    if let note = highlight.note, !note.isEmpty {
                        Text(note).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(4)
                    }
                    Text(ReaderModel.describe(highlight.locator, publication: model.publication))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 14))
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
            .glassEffect(.regular, in: .capsule)
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            .onChange(of: model.searchQuery) { _, q in model.search(q) }

            if model.publication?.kind == .comic {
                Text("Comics don’t contain searchable text.").font(.callout).foregroundStyle(.secondary).padding(.top, 30)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if !model.searchResults.isEmpty {
                            Text("\(model.searchResults.count)\(model.searchResults.count >= 500 ? "+" : "") results")
                                .font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.horizontal, 4)
                        }
                        ForEach(model.searchResults) { r in
                            Button { model.reveal(r) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    if !r.chapter.isEmpty {
                                        Text(r.chapter).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Text(r.snippet).font(.system(size: 12.5, design: .serif)).foregroundStyle(.secondary).lineLimit(3)
                                        .multilineTextAlignment(.leading)
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 12))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                }
                .scrollEdgeEffectStyle(.soft, for: .all)
            }
        }
        .onAppear { focused = true }
    }
}

// MARK: Settings

struct ReaderSettingsPopover: View {
    let kind: PublicationKind
    @State private var settings = ReaderSettings.shared

    var body: some View {
        @Bindable var s = settings
        VStack(alignment: .leading, spacing: 16) {
            themeGrid

            if kind == .reflowable {
                HStack(spacing: 10) {
                    Button { s.prefs.fontSize = max(12, s.prefs.fontSize - 1) } label: {
                        Text("A").font(.system(size: 13, design: .serif)).frame(maxWidth: .infinity, minHeight: 26)
                    }
                    Text("\(Int(s.prefs.fontSize))").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 28)
                    Button { s.prefs.fontSize = min(40, s.prefs.fontSize + 1) } label: {
                        Text("A").font(.system(size: 21, design: .serif)).frame(maxWidth: .infinity, minHeight: 26)
                    }
                }
                .buttonStyle(.glass)

                Picker("Font", selection: $s.prefs.fontID) {
                    ForEach(ReaderFont.all) { f in
                        Text(f.name).font(f.preview(size: 13)).tag(f.id)
                    }
                }

                labeledSlider("Line Spacing", value: $s.prefs.lineHeight, range: 1.1...2.2, icon: "line.3.horizontal")
                labeledSlider("Margins", value: $s.prefs.margin, range: 16...140, icon: "arrow.left.and.right.text.vertical")

                HStack {
                    Toggle("Justify", isOn: $s.prefs.justify)
                    Spacer()
                    Toggle("Hyphenate", isOn: $s.prefs.hyphenate)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            if kind != .comic {
                Picker("Layout", selection: $s.prefs.layout) {
                    ForEach(PageLayout.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Picker("Pages", selection: $s.prefs.spread) {
                ForEach(SpreadMode.allCases) { Text($0.name).tag($0) }
            }
            .pickerStyle(.segmented)

            if kind == .reflowable {
                Toggle("Animate page turns", isOn: $s.prefs.pageTurnAnimation).controlSize(.small)
            }
            if kind == .pdf {
                Toggle("Dim pages in dark themes", isOn: $s.prefs.dimPDFInDarkThemes).controlSize(.small)
            }
            if kind == .comic {
                Toggle("Right-to-left (manga)", isOn: Binding(
                    get: { s.prefs.comicRightToLeft ?? false },
                    set: { s.prefs.comicRightToLeft = $0 }
                )).controlSize(.small)
            }
        }
        .padding(18)
        .frame(width: 320)
    }

    private var themeGrid: some View {
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
                                .foregroundStyle(theme == .auto ? Color.gray : resolved.foregroundColor)
                        }
                        .frame(height: 40)
                        .clipShape(.rect(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(settings.prefs.theme == theme ? Color.accentColor : .primary.opacity(0.12),
                                              lineWidth: settings.prefs.theme == theme ? 2.5 : 1)
                        }
                        Text(theme.name).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func labeledSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 20).help(title).accessibilityHidden(true)
            Slider(value: value, in: range).accessibilityLabel(title).controlSize(.small).tint(Color(hex: "#C96442"))
        }
    }
}
