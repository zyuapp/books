import AppKit
import SwiftUI

struct ReaderWindow: View {
    let bookID: String
    @State private var library = LibraryStore.shared

    var body: some View {
        if let book = library.book(bookID) {
            ReaderView(book: book)
        } else if !library.scannedOnce {
            ProgressView().frame(minWidth: 600, minHeight: 500)
        } else {
            ContentUnavailableView {
                Label("Book Not Found", systemImage: "book.closed")
            } description: {
                Text("This book is no longer in your library.")
            } actions: {
                Button("Back to Library") { OpenBridge.shared.showLibrary() }
            }
            .frame(minWidth: 600, minHeight: 500)
        }
    }
}

struct ReaderView: View {
    @State private var model: ReaderModel
    @State private var chat: ClaudeChat
    @State private var settings = ReaderSettings.shared
    @Environment(\.colorScheme) private var colorScheme
    /// Engines and panels wait for the screen fade: building them during it drops frames.
    @State private var contentMounted = false
    @State private var selectionBarWidth: CGFloat = 430

    init(book: BookRecord) {
        let m = ReaderModel(book: book)
        _model = State(initialValue: m)
        _chat = State(initialValue: ClaudeChat(reader: m))
    }

    private var theme: ReaderTheme { settings.prefs.theme.resolved(dark: colorScheme == .dark) }
    private var chromeShown: Bool { model.chromeVisible || model.panel != nil || model.showClaude }
    /// The page lays out beside open panels, so they never cover what's being read.
    private var panelInset: CGFloat { model.panel == nil ? 0 : SidePanel.width + SidePanel.edgeInset }
    private var claudeInset: CGFloat { model.showClaude && !model.claudeExpanded ? ClaudePanel.compactWidth + 12 : 0 }

    var body: some View {
        ZStack {
            theme.backgroundColor.ignoresSafeArea()
            content
                .padding(.leading, panelInset)
                .padding(.trailing, claudeInset)
                .transaction { $0.animation = nil }
                .ignoresSafeArea()
            if !model.isContentReady && model.loadError == nil {
                loadingCover
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
            overlays
                .ignoresSafeArea(edges: .top)
        }
        .frame(minWidth: 640, minHeight: 520)
        .navigationTitle(model.title)
        .background(WindowChrome(model: model, visible: chromeShown))
        .focusedSceneValue(\.readerModel, model)
        .task { await model.load() }
        .task {
            await AppNavigation.shared.settled()
            contentMounted = true
        }
        .animation(Motion.popup, value: model.isContentReady)
        .animation(Motion.popup, value: contentMounted)
        .onDisappear { LibraryStore.shared.saveAllInBackground() }
        .sheet(item: $model.noteEditor) { h in
            NoteEditor(highlight: h) { note in
                model.updateHighlight(h.id) { $0.note = note.isEmpty ? nil : note }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let pub = model.publication {
            if contentMounted {
                switch pub.kind {
                case .reflowable:
                    WebReaderView(model: model, publication: pub, isDark: colorScheme == .dark, prefs: settings.prefs)
                case .pdf:
                    PDFReaderView(model: model, publication: pub, isDark: colorScheme == .dark, prefs: settings.prefs)
                case .comic:
                    ComicReaderView(model: model, publication: pub, prefs: settings.prefs)
                }
            }
        } else if let error = model.loadError {
            ContentUnavailableView {
                Label("Can’t Open Book", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            }
            .foregroundStyle(theme.foregroundColor)
        }
    }

    /// Hides the engine until its first page is placed and rendered.
    private var loadingCover: some View {
        ZStack {
            theme.backgroundColor
            if contentMounted {
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    Text(model.isDownloading ? "Downloading from iCloud…" : "Opening…")
                        .font(.callout).foregroundStyle(theme.secondaryColor)
                }
                .transition(.opacity)
            }
        }
    }

    private var overlays: some View {
        GeometryReader { geo in
            ZStack {
                VStack(spacing: 0) {
                    ZStack {
                        if chromeShown {
                            TopBar(model: model, theme: theme)
                                .transition(.opacity.combined(with: .offset(y: -12)))
                        }
                    }
                    .frame(height: HeaderBar<EmptyView, EmptyView>.height)
                    .frame(maxWidth: .infinity)
                    .background {
                        // Keeps zoomed-in page text from showing through the title.
                        if model.zoomPercent != nil && chromeShown {
                            theme.backgroundColor
                                .allowsHitTesting(false)
                                .transition(.opacity)
                        }
                    }
                    if model.showBackPill && model.canGoBack {
                        BackPill(model: model)
                            .padding(.top, 6)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    Spacer()
                    if model.publication != nil && model.chromeVisible {
                        BottomBar(model: model, theme: theme)
                            .padding(.leading, panelInset)
                            .padding(.trailing, claudeInset)
                            .transition(.opacity.combined(with: .offset(y: 12)))
                    }
                }

                HStack(alignment: .top, spacing: 0) {
                    if contentMounted {
                        // Stays mounted and slides off-window, so opening only moves an already-built panel.
                        SidePanel(model: model)
                            .padding(.leading, SidePanel.edgeInset)
                            .padding(.top, 56)
                            .padding(.bottom, 12)
                            .frame(width: model.panel == nil ? 0 : SidePanel.width + SidePanel.edgeInset, alignment: .leading)
                            .offset(x: model.panel == nil ? -SidePanel.closedOffset : 0)
                            .allowsHitTesting(model.panel != nil)
                            .accessibilityHidden(model.panel == nil)
                    }
                    if !(model.showClaude && model.claudeExpanded) { Spacer(minLength: 0) }
                    if model.showClaude {
                        ClaudePanel(reader: model, chat: chat, theme: theme)
                            .padding(.trailing, model.claudeExpanded ? 0 : 12)
                            .padding(.top, model.claudeExpanded ? HeaderBar<EmptyView, EmptyView>.height : 56)
                            .padding(.bottom, model.claudeExpanded ? 0 : 12)
                            .transition(.move(edge: .trailing))
                    }
                }

                if model.showSettings {
                    ReaderSettingsPopover(kind: model.publication?.kind ?? .reflowable, reader: model)
                        .readerPanelSurface(theme, cornerRadius: 20)
                        .readerOverlay()
                        .padding(.top, 56)
                        .padding(.trailing, 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topTrailing)))
                }
                if let sel = model.selection, sel.rect.isFinite {
                    let x = selectionBarX(sel.rect, in: geo.size)
                    SelectionBar(model: model, selection: sel, pointerOffset: sel.rect.midX - x, pointsDown: barAbove(sel.rect))
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { selectionBarWidth = $0 }
                        .position(x: x, y: selectionBarY(sel.rect, in: geo.size))
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
                if let sel = model.selection, sel.rect.isFinite, let note = highlightNote(sel) {
                    NoteCard(label: "Your Note", symbol: "note.text", text: note, actionTitle: "Edit", action: { model.addNoteToSelection() }) {
                        model.selection = nil
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: noteCardBelow(sel.rect, in: geo.size) ? .topLeading : .bottomLeading)
                    .offset(noteCardOffset(sel.rect, in: geo.size))
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
                if let note = model.footnote, note.rect.isFinite {
                    NoteCard(label: "Note", symbol: "text.append", text: note.text,
                             actionTitle: "Go to Note", action: note.link.map { url in { model.openLink(url) } }) { model.footnote = nil }
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: note.rect.maxY < geo.size.height * 0.6 ? .topLeading : .bottomLeading)
                        .offset(footnoteOffset(note.rect, in: geo.size))
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
            .onPreferenceChange(OverlayFramesKey.self) { rects in model.overlayRects = rects }
            .animation(Motion.popup, value: model.selection)
            .animation(Motion.popup, value: model.showSettings)
            .animation(Motion.popup, value: model.footnote)
            .animation(Motion.panel, value: model.panel)
            .animation(Motion.panel, value: model.showClaude)
            .animation(Motion.panel, value: model.claudeExpanded)
            .animation(Motion.popup, value: model.zoomPercent == nil)
            .animation(Motion.popup, value: model.chromeVisible)
        }
    }

    private static let barHeight: CGFloat = 34
    /// Clearance between the selection and the bar, including its pointer.
    private static let barGap: CGFloat = 12

    private func barAbove(_ rect: CGRect) -> Bool { rect.minY - Self.barHeight - Self.barGap >= 60 }

    private func selectionBarX(_ rect: CGRect, in size: CGSize) -> CGFloat {
        min(max(rect.midX, selectionBarWidth / 2 + 12), size.width - selectionBarWidth / 2 - 12)
    }

    private func selectionBarY(_ rect: CGRect, in size: CGSize) -> CGFloat {
        let half = Self.barHeight / 2
        let y = barAbove(rect) ? rect.minY - half - Self.barGap : rect.maxY + half + Self.barGap
        return min(max(y, Self.barHeight), size.height - Self.barHeight)
    }

    private func highlightNote(_ sel: ReaderSelection) -> String? {
        guard let id = sel.highlightID, let note = model.state.liveHighlights.first(where: { $0.id == id })?.note,
              !note.isEmpty else { return nil }
        return note
    }

    /// The note card sits on the side of the passage away from the selection bar, or past the bar when that side lacks room.
    private func noteCardBelow(_ rect: CGRect, in size: CGSize) -> Bool {
        !barAbove(rect) || rect.maxY < size.height * 0.6
    }

    private func noteCardOffset(_ rect: CGRect, in size: CGSize) -> CGSize {
        let w: CGFloat = 360, pastBar = Self.barGap + Self.barHeight
        let x = min(max(rect.midX - w / 2, 16), size.width - w - 16)
        if !barAbove(rect) { return CGSize(width: x, height: rect.maxY + pastBar + 10) }
        return rect.maxY < size.height * 0.6
            ? CGSize(width: x, height: rect.maxY + 10)
            : CGSize(width: x, height: -(size.height - rect.minY + pastBar + 10))
    }

    private func footnoteOffset(_ rect: CGRect, in size: CGSize) -> CGSize {
        let w: CGFloat = 360
        let x = min(max(rect.midX - w / 2, 16), size.width - w - 16)
        return rect.maxY < size.height * 0.6
            ? CGSize(width: x, height: rect.maxY + 10)
            : CGSize(width: x, height: -(size.height - rect.minY + 10))
    }
}

// MARK: - Bars

private struct TopBar: View {
    let model: ReaderModel
    let theme: ReaderTheme

    var body: some View {
        HeaderBar(title: model.title.mainTitle, subtitle: subtitle, serif: true, titleColor: theme.foregroundColor.opacity(0.85)) {
            HeaderButtonGroup {
                HeaderButton(symbol: "chevron.left", label: "Back to Library", tooltip: "Back to Library (⇧⌘L)") {
                    OpenBridge.shared.showLibrary()
                }
                panelButton(.contents, symbol: "list.bullet", label: "Contents", shortcut: "⌥⌘T")
                if model.publication?.kind != .comic {
                    panelButton(.notes, symbol: "highlighter", label: "Highlights & Bookmarks", shortcut: "⌥⌘N")
                    panelButton(.search, symbol: "magnifyingglass", label: "Search", shortcut: "⌘F")
                }
            }
            .readerOverlay()
        } trailing: {
            HeaderButtonGroup {
                HeaderButton(symbol: "textformat.size", label: "Reading Settings", tooltip: "Reading Settings (⌥⌘A)", active: model.showSettings) {
                    model.showSettings.toggle()
                }
                HeaderButton(symbol: model.isBookmarked ? "bookmark.fill" : "bookmark", label: "Bookmark", tooltip: "Bookmark This Page (⌘D)",
                             color: model.isBookmarked ? Color(hex: "#E25B45") : nil) {
                    model.toggleBookmark()
                }
                HeaderButton(symbol: "sparkles", label: "Ask Claude", tooltip: "Ask Claude (⌘L)", active: model.showClaude) {
                    if model.showClaude { model.showClaude = false } else { model.askClaude(action: nil) }
                }
            }
            .readerOverlay()
        }
    }

    private var subtitle: String? {
        guard let publication = model.publication else { return nil }
        let chapter = model.chapterTitle.flatMap { $0 == model.title ? nil : $0 }
        return publication.kind == .comic ? nil : chapter
    }

    private func panelButton(_ panel: ReaderPanel, symbol: String, label: String, shortcut: String) -> some View {
        HeaderButton(symbol: symbol, label: label, tooltip: "\(label) (\(shortcut))", active: model.panel == panel) {
            model.panel = model.panel == panel ? nil : panel
        }
    }
}

private struct BottomBar: View {
    let model: ReaderModel
    let theme: ReaderTheme
    @State private var scrubValue: Double?

    var body: some View {
        let progress = scrubValue ?? model.location.totalProgress
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                if model.isPaginatedLayout {
                    pageButton(symbol: "chevron.left", label: "Previous Page (←)", forward: model.pagesRightToLeft)
                }
                Text(leftLabel)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary.opacity(0.7))
                    .lineLimit(1)
                    .frame(minWidth: 110, alignment: model.isPaginatedLayout ? .center : .leading)
                if model.isPaginatedLayout {
                    pageButton(symbol: "chevron.right", label: "Next Page (→)", forward: !model.pagesRightToLeft)
                }
            }
            Slider(value: Binding(
                get: { progress },
                set: { v in
                    if scrubValue == nil { model.beginScrub() }
                    scrubValue = v
                    model.scrub(toProgress: v)
                }
            ), in: 0...1) { editing in
                if !editing { scrubValue = nil }
            }
            .tint(Color.brand)
            .controlSize(.small)
            .frame(minWidth: 80, maxWidth: 340)
            Text("\(Int((progress * 100).rounded()))%")
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary.opacity(0.7))
                .frame(width: 38, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .readerPanelSurface(theme, cornerRadius: 23)
        .readerOverlay()
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    private func pageButton(symbol: String, label: String, forward: Bool) -> some View {
        Button { forward ? model.nextPage() : model.previousPage() } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary.opacity(0.65))
        .tooltip(label)
        .accessibilityLabel(label)
    }

    private var leftLabel: String {
        guard let pub = model.publication else { return "" }
        switch pub.kind {
        case .pdf, .comic: return "Page \(model.location.index + 1) of \(pub.spine.count)"
        case .reflowable:
            let left = max(0, model.pagesInChapter - model.pageInChapter - 1)
            if ReaderSettings.shared.prefs.layout == .scroll { return model.chapterTitle ?? "" }
            return left == 0 ? "Last page in chapter" : "\(left) page\(left == 1 ? "" : "s") left in chapter"
        }
    }
}

private struct BackPill: View {
    let model: ReaderModel

    var body: some View {
        HStack(spacing: 2) {
            Button { withAnimation(.snappy) { model.goBack() } } label: {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 12, weight: .bold))
                    Text("Back to \(model.backLabel)").font(.body.weight(.medium)).lineLimit(1)
                }
                .padding(.leading, 14)
                .padding(.trailing, 6)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tooltip("Undo Jump (⌘Z)")
            Divider().frame(height: 16)
            Button { withAnimation { model.showBackPill = false } } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 28, height: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.trailing, 4)
        .glassSurface(in: .capsule, interactive: true)
        .readerOverlay()
    }
}

private struct SelectionBar: View {
    let model: ReaderModel
    let selection: ReaderSelection
    var pointerOffset: CGFloat = 0
    var pointsDown = true
    @Environment(\.colorScheme) private var colorScheme

    private var surface: ReaderTheme { ReaderSettings.shared.prefs.theme.resolved(dark: colorScheme == .dark) }
    private var raised: Color { surface.isDark ? .white.opacity(0.12) : .white }

    var body: some View {
        let existing = selection.highlightID.flatMap { id in model.state.liveHighlights.first { $0.id == id } }
        HStack(spacing: 2) {
            HStack(spacing: 6) {
                ForEach(HighlightColor.allCases, id: \.self) { c in
                    Button { model.highlightSelection(c) } label: {
                        ZStack {
                            if c == .underline {
                                Image(systemName: "underline").font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
                            } else {
                                Circle().fill(c.color.gradient).frame(width: 17, height: 17)
                            }
                            if existing?.color == c {
                                Circle().strokeBorder(.primary.opacity(0.6), lineWidth: 1.5).frame(width: 23, height: 23)
                            }
                        }
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .tooltip(c == .underline ? "Underline" : "Highlight \(c.rawValue.capitalized)")
                    .accessibilityLabel(c == .underline ? "Underline" : "Highlight \(c.rawValue)")
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)

            divider

            iconButton("note.text.badge.plus", existing?.note == nil ? "Add Note" : "Edit Note") { model.addNoteToSelection() }
            iconButton("doc.on.doc", "Copy") { model.copySelection() }
            if let existing {
                iconButton("trash", "Remove", role: .destructive) { model.deleteHighlight(existing.id) }
            }

            divider

            Button { model.askClaude(action: nil) } label: {
                Label("Ask Claude", systemImage: "sparkles")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background(Color.brand.gradient, in: .capsule)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.leading, 6)
            .padding(.trailing, 4)
            .tooltip("Ask Claude about this passage (⌘L). Right-click for quick actions.")
            .contextMenu {
                ForEach(ClaudeQuickAction.allCases) { a in
                    Button(a.title, systemImage: a.symbol) { model.askClaude(action: a) }
                }
            }
        }
        .frame(height: 34)
        .background(raised, in: .capsule)
        .overlay(Capsule().strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
        .readerPanelSurface(surface, cornerRadius: 17)
        .fixedSize()
        .overlay(alignment: pointsDown ? .bottom : .top) {
            GeometryReader { geo in
                PointerTriangle()
                    .fill(raised)
                    .background(PointerTriangle().fill(surface.backgroundColor))
                    .overlay(PointerTriangle().stroke(.primary.opacity(0.14), lineWidth: 0.5))
                    .shadow(color: .black.opacity(surface.isDark ? 0.4 : 0.16), radius: 3, y: 2)
                    .frame(width: 20, height: 9)
                    .rotationEffect(pointsDown ? .zero : .degrees(180))
                    .position(x: geo.size.width / 2 + min(max(pointerOffset, 26 - geo.size.width / 2), geo.size.width / 2 - 26),
                              y: pointsDown ? geo.size.height + 3 : -3)
            }
            .allowsHitTesting(false)
        }
        .readerOverlay()
    }

    private var divider: some View {
        Divider().frame(height: 18).padding(.horizontal, 4)
    }

    private func iconButton(_ symbol: String, _ title: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(role == .destructive ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                .frame(width: 32, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tooltip(title)
        .accessibilityLabel(title)
    }
}

private struct PointerTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct NoteCard: View {
    let label: String
    let symbol: String
    let text: String
    let actionTitle: String
    let action: (() -> Void)?
    let dismiss: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(label, systemImage: symbol).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let action {
                    Button(actionTitle, action: action).buttonStyle(.borderless).font(.subheadline.weight(.medium))
                }
                Button(action: dismiss) { Image(systemName: "xmark").font(.caption.weight(.bold)) }.buttonStyle(.borderless)
            }
            let content = Text(text)
                .font(.system(.title3, design: .serif))
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if text.count > 420 {
                ScrollView { content }.frame(height: 220)
            } else {
                content.fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 360)
        .readerPanelSurface(ReaderSettings.shared.prefs.theme.resolved(dark: colorScheme == .dark), cornerRadius: 20)
        .readerOverlay()
    }
}

private struct NoteEditor: View {
    let highlight: Highlight
    let save: (String) -> Void
    @State private var text: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    init(highlight: Highlight, save: @escaping (String) -> Void) {
        self.highlight = highlight
        self.save = save
        _text = State(initialValue: highlight.note ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(highlight.note == nil ? "Add Note" : "Edit Note").font(.system(size: 18, weight: .semibold, design: .serif))
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(highlight.color.color).frame(width: 3)
                Text(highlight.text).font(.custom("Charter", size: 14)).lineLimit(5).foregroundStyle(.primary.opacity(0.85))
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(highlight.color.color.opacity(0.18), in: .rect(cornerRadius: 10))
            .fixedSize(horizontal: false, vertical: true)
            if let chapter = highlight.locator.label {
                Text(chapter).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Write a note…").foregroundStyle(.tertiary).padding(.leading, 5).allowsHitTesting(false)
                    }
                }
                .padding(8)
                .background(.primary.opacity(0.06), in: .rect(cornerRadius: 12))
                .frame(minHeight: 140)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save(text); dismiss() }.keyboardShortcut(.defaultAction).glassProminentButtonStyle().tint(Color.brand)
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(ReaderSettings.shared.prefs.theme.resolved(dark: colorScheme == .dark).backgroundColor)
    }
}

/// Window plumbing for the reader: shortcuts, full-screen tracking and traffic-light fading.
private struct WindowChrome: NSViewRepresentable {
    let model: ReaderModel
    let visible: Bool

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onWindow = { [weak coordinator = context.coordinator] window in coordinator?.attach(window) }
        return view
    }

    static func dismantleNSView(_ view: TrackingView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        let coordinator = context.coordinator
        guard coordinator.buttonsVisible != visible else { return }
        coordinator.buttonsVisible = visible
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let button = window.standardWindowButton(type) else { continue }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.22
                    button.animator().alphaValue = visible ? 1 : 0
                }
            }
        }
    }

    final class TrackingView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }

    @MainActor
    final class Coordinator {
        let model: ReaderModel
        var buttonsVisible = true
        private weak var window: NSWindow?
        private var monitor: Any?
        private var observers: [NSObjectProtocol] = []

        init(model: ReaderModel) { self.model = model }

        func attach(_ window: NSWindow) {
            guard self.window !== window else { return }
            detach()
            self.window = window
            window.acceptsMouseMovedEvents = true
            model.isFullScreen = window.styleMask.contains(.fullScreen)
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .mouseMoved]) { [weak self] event in
                guard let self, let window = self.window, event.window === window, window.isKeyWindow else { return event }
                if event.type == .mouseMoved {
                    let y = event.locationInWindow.y
                    if self.model.isFullScreen, let content = window.contentView,
                       y > content.bounds.height - 100 || y < 90 { self.model.pokeChrome() }
                    return event
                }
                return ReaderKeys.handle(event, model: self.model, window: window) ? nil : event
            }
            let center = NotificationCenter.default
            for (name, value) in [(NSWindow.didEnterFullScreenNotification, true), (NSWindow.didExitFullScreenNotification, false)] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.model.isFullScreen = value }
                })
            }
        }


        func detach() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            if let window {
                for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                    window.standardWindowButton(type)?.alphaValue = 1
                }
            }
            window = nil
        }
    }
}

struct ReaderModelKey: FocusedValueKey {
    typealias Value = ReaderModel
}

extension FocusedValues {
    var readerModel: ReaderModel? {
        get { self[ReaderModelKey.self] }
        set { self[ReaderModelKey.self] = newValue }
    }
}

// MARK: Tooltips

extension View {
    /// Shows `text` beneath the pointer after a short hover. `.help` doesn't show over the page.
    func tooltip(_ text: String) -> some View {
        background(TooltipAnchor(text: text)).accessibilityHint(text)
    }
}

private struct TooltipAnchor: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> TooltipAnchorView { TooltipAnchorView() }
    func updateNSView(_ view: TooltipAnchorView, context: Context) { view.text = text }
}

private final class TooltipAnchorView: NSView {
    var text = ""

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard trackingAreas.isEmpty else { return }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { TooltipPresenter.shared.hover(self) }
    override func mouseExited(with event: NSEvent) { TooltipPresenter.shared.leave(self) }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { TooltipPresenter.shared.leave(self) }
    }
}

@MainActor
private final class TooltipPresenter {
    static let shared = TooltipPresenter()

    private static let delay: TimeInterval = 0.25
    /// Moving to another control this soon after a tooltip closed shows the next one at once.
    private static let followOnWindow: TimeInterval = 0.5
    /// Keeps the bubble clear of the cursor image, which extends below the pointer's hot spot.
    private static let cursorClearance: CGFloat = 20
    private static let gapAbovePointer: CGFloat = 6
    private static let screenMargin: CGFloat = 4

    private let panel: NSPanel
    private let label = NSTextField(wrappingLabelWithString: "")
    private weak var anchor: TooltipAnchorView?
    private var pending: DispatchWorkItem?
    private var closedAt = Date.distantPast

    private init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]

        let bubble = NSVisualEffectView()
        bubble.material = .toolTip
        bubble.state = .active
        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = 6
        bubble.layer?.masksToBounds = true
        panel.contentView = bubble

        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.preferredMaxLayoutWidth = 280
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -4),
        ])

        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
            self?.close()
            return event
        }
    }

    func hover(_ view: TooltipAnchorView) {
        close()
        anchor = view
        let work = DispatchWorkItem { [weak self] in self?.show() }
        pending = work
        let delay = Date().timeIntervalSince(closedAt) < Self.followOnWindow ? 0 : Self.delay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func leave(_ view: TooltipAnchorView) {
        if anchor === view { close() }
    }

    private func close() {
        pending?.cancel()
        pending = nil
        anchor = nil
        guard panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        closedAt = Date()
    }

    private func show() {
        guard let anchor, let window = anchor.window, !anchor.text.isEmpty else { return }
        label.stringValue = anchor.text
        panel.appearance = window.effectiveAppearance
        panel.contentView?.layoutSubtreeIfNeeded()
        let size = panel.contentView?.fittingSize ?? .zero
        let pointer = NSEvent.mouseLocation
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        let x = max(min(pointer.x, screen.maxX - size.width - Self.screenMargin), screen.minX + Self.screenMargin)
        let below = pointer.y - Self.cursorClearance - size.height
        let y = below >= screen.minY + Self.screenMargin ? below : pointer.y + Self.gapAbovePointer
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
    }
}
