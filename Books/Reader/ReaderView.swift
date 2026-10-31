import AppKit
import SwiftUI

struct ReaderWindow: View {
    let bookID: String
    @State private var library = LibraryStore.shared

    var body: some View {
        if let book = library.book(bookID) {
            ReaderView(book: book)
        } else if library.isScanning || library.books.isEmpty {
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

    init(book: BookRecord) {
        let m = ReaderModel(book: book)
        _model = State(initialValue: m)
        _chat = State(initialValue: ClaudeChat(reader: m))
    }

    private var theme: ReaderTheme { settings.prefs.theme.resolved(dark: colorScheme == .dark) }

    var body: some View {
        ZStack {
            theme.backgroundColor.ignoresSafeArea()
            content
                .ignoresSafeArea()
            overlays
        }
        .frame(minWidth: 640, minHeight: 520)
        .preferredColorScheme(settings.prefs.theme == .auto ? nil : (theme.isDark ? .dark : .light))
        .navigationTitle(model.title)
        .toolbar(removing: .title)
        .toolbar(.hidden, for: .windowToolbar)
        .background(WindowChrome(model: model, visible: model.chromeVisible || model.panel != nil || model.showClaude))
        .focusedSceneValue(\.readerModel, model)
        .task { await model.load() }
        .onDisappear { LibraryStore.shared.flushAll() }
        .sheet(item: $model.noteEditor) { h in
            NoteEditor(highlight: h) { note in
                model.updateHighlight(h.id) { $0.note = note.isEmpty ? nil : note }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let pub = model.publication {
            switch pub.kind {
            case .reflowable:
                WebReaderView(model: model, publication: pub, isDark: colorScheme == .dark, prefs: settings.prefs)
            case .pdf:
                PDFReaderView(model: model, publication: pub, isDark: colorScheme == .dark, prefs: settings.prefs)
            case .comic:
                ComicReaderView(model: model, publication: pub, prefs: settings.prefs)
            }
        } else if let error = model.loadError {
            ContentUnavailableView {
                Label("Can’t Open Book", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            }
            .foregroundStyle(theme.foregroundColor)
        } else {
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text(model.isDownloading ? "Downloading from iCloud…" : "Opening…")
                    .font(.callout).foregroundStyle(theme.secondaryColor)
            }
        }
    }

    private var overlays: some View {
        GeometryReader { geo in
            ZStack {
                VStack(spacing: 0) {
                    ZStack {
                        if model.chromeVisible || model.panel != nil || model.showClaude {
                            TopBar(model: model, theme: theme)
                                .transition(.opacity.combined(with: .offset(y: -12)))
                        }
                    }
                    .frame(height: 52)
                    if model.showBackPill && model.canGoBack {
                        BackPill(model: model)
                            .padding(.top, 6)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    Spacer()
                    if model.publication != nil && model.chromeVisible {
                        BottomBar(model: model, theme: theme)
                            .transition(.opacity.combined(with: .offset(y: 12)))
                    }
                }

                HStack(alignment: .top, spacing: 0) {
                    if let panel = model.panel {
                        SidePanel(model: model, panel: panel)
                            .padding(.leading, 12)
                            .padding(.top, 56)
                            .padding(.bottom, 12)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    Spacer(minLength: 0)
                    if model.showClaude {
                        ClaudePanel(reader: model, chat: chat, theme: theme)
                            .padding(.trailing, 12)
                            .padding(.top, 56)
                            .padding(.bottom, 12)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }

                if let sel = model.selection {
                    SelectionBar(model: model, selection: sel)
                        .position(selectionBarPosition(sel.rect, in: geo.size))
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
                if let note = model.footnote {
                    FootnoteCard(note: note, theme: theme, open: note.link.map { url in { model.openLink(url) } }) { model.footnote = nil }
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: note.rect.maxY < geo.size.height * 0.6 ? .topLeading : .bottomLeading)
                        .offset(footnoteOffset(note.rect, in: geo.size))
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
            .onPreferenceChange(OverlayFramesKey.self) { rects in model.overlayRects = rects }
            .animation(.spring(duration: 0.32), value: model.selection)
            .animation(.spring(duration: 0.3), value: model.footnote)
            .animation(.spring(duration: 0.4), value: model.panel)
            .animation(.spring(duration: 0.4), value: model.showClaude)
            .animation(.easeInOut(duration: 0.35), value: model.chromeVisible)
        }
    }

    private func selectionBarPosition(_ rect: CGRect, in size: CGSize) -> CGPoint {
        let barHeight: CGFloat = 46, barWidth: CGFloat = 560
        var y = rect.minY - barHeight / 2 - 22
        if y < 90 { y = rect.maxY + barHeight / 2 + 22 }
        let x = min(max(rect.midX, barWidth / 2 + 12), size.width - barWidth / 2 - 12)
        return CGPoint(x: x, y: min(max(y, barHeight), size.height - barHeight))
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
    @State private var settings = ReaderSettings.shared

    var body: some View {
        HStack(spacing: 12) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 6) {
                    Button { OpenBridge.shared.showLibrary() } label: {
                        Image(systemName: "chevron.left").fontWeight(.semibold).frame(width: 18, height: 18)
                    }
                    .buttonStyle(.glass)
                    .help("Back to Library (⇧⌘L)")
                    .accessibilityLabel("Back to Library")
                    panelButton(.contents, symbol: "list.bullet", help: "Contents")
                    panelButton(.notes, symbol: "highlighter", help: "Highlights & Bookmarks")
                    panelButton(.search, symbol: "magnifyingglass", help: "Search")
                }
            }
            .readerOverlay()
            .padding(.leading, 78)

            Spacer(minLength: 12)

            VStack(spacing: 1) {
                Text(model.title)
                    .font(.system(size: 13, weight: .semibold, design: .serif))
                    .lineLimit(1)
                if let chapter = model.chapterTitle, chapter != model.title {
                    Text(chapter).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .foregroundStyle(theme.foregroundColor.opacity(0.85))
            .frame(maxWidth: 420)

            Spacer(minLength: 12)

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 6) {
                    Button { model.showSettings.toggle() } label: {
                        Image(systemName: "textformat.size").frame(width: 18, height: 18)
                    }
                    .buttonStyle(.glass)
                    .help("Reading Settings")
                    .accessibilityLabel("Reading Settings")
                    .popover(isPresented: Binding(get: { model.showSettings }, set: { model.showSettings = $0 }), arrowEdge: .bottom) {
                        ReaderSettingsPopover(kind: model.publication?.kind ?? .reflowable)
                    }

                    Button { model.toggleBookmark() } label: {
                        Image(systemName: model.isBookmarked ? "bookmark.fill" : "bookmark")
                            .foregroundStyle(model.isBookmarked ? Color(hex: "#E25B45") : .primary)
                            .frame(width: 18, height: 18)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.glass)
                    .help("Bookmark This Page (⌘D)")
                    .accessibilityLabel("Bookmark")

                    Button {
                        if model.showClaude { model.showClaude = false } else { model.askClaude(action: nil) }
                    } label: {
                        Image(systemName: "sparkles").frame(width: 18, height: 18)
                    }
                    .buttonStyle(.glass)
                    .tint(model.showClaude ? Color(hex: "#C96442") : nil)
                    .help("Ask Claude (⌘L)")
                    .accessibilityLabel("Ask Claude")
                }
            }
            .readerOverlay()
            .padding(.trailing, 14)
        }
        .controlSize(.large)
        .frame(height: 52)
    }

    private func panelButton(_ panel: ReaderPanel, symbol: String, help: String) -> some View {
        Button {
            model.panel = model.panel == panel ? nil : panel
        } label: {
            Image(systemName: symbol).frame(width: 18, height: 18)
        }
        .buttonStyle(.glass)
        .tint(model.panel == panel ? Color.accentColor : nil)
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct BottomBar: View {
    let model: ReaderModel
    let theme: ReaderTheme
    @State private var scrubValue: Double?

    var body: some View {
        let progress = scrubValue ?? model.location.totalProgress
        HStack(spacing: 14) {
            Text(leftLabel)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(minWidth: 110, alignment: .leading)
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
            .tint(Color(hex: "#C96442"))
            .controlSize(.small)
            .frame(minWidth: 160, maxWidth: 380)
            Text("\(Int((progress * 100).rounded()))%")
                .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: .capsule)
        .readerOverlay()
        .padding(.bottom, 14)
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
                    Text("Back to \(model.backLabel)").font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                }
                .padding(.leading, 14)
                .padding(.trailing, 6)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Undo Jump (⌘Z)")
            Divider().frame(height: 16)
            Button { withAnimation { model.showBackPill = false } } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 28, height: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.trailing, 4)
        .glassEffect(.regular.interactive(), in: .capsule)
        .readerOverlay()
    }
}

private struct SelectionBar: View {
    let model: ReaderModel
    let selection: ReaderSelection
    @Environment(\.self) private var env

    var body: some View {
        let existing = selection.highlightID.flatMap { id in model.state.liveHighlights.first { $0.id == id } }
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 4) {
                HStack(spacing: 7) {
                    ForEach(HighlightColor.allCases, id: \.self) { c in
                        Button { model.highlightSelection(c) } label: {
                            ZStack {
                                if c == .underline {
                                    Image(systemName: "underline").font(.system(size: 12, weight: .bold)).foregroundStyle(c.color)
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
                        .help(c == .underline ? "Underline" : "Highlight \(c.rawValue.capitalized)")
                        .accessibilityLabel(c == .underline ? "Underline" : "Highlight \(c.rawValue)")
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 38)
                .glassEffect(.regular, in: .capsule)

                HStack(spacing: 0) {
                    labeledButton("note.text.badge.plus", existing?.note == nil ? "Add Note" : "Edit Note") { model.addNoteToSelection() }
                    labeledButton("doc.on.doc", "Copy") { model.copySelection() }
                    if let existing {
                        labeledButton("trash", "Remove", role: .destructive) { model.deleteHighlight(existing.id) }
                    }
                }
                .padding(.horizontal, 4)
                .frame(height: 38)
                .glassEffect(.regular, in: .capsule)

                Button { model.askClaude(action: nil) } label: {
                    Label("Ask Claude", systemImage: "sparkles").font(.callout.weight(.semibold))
                }
                .buttonStyle(.glassProminent)
                .tint(Color(hex: "#C96442"))
                .controlSize(.large)
                .help("Ask Claude about this passage (⌘L). Right-click for quick actions.")
                .contextMenu {
                    ForEach(ClaudeQuickAction.allCases) { a in
                        Button(a.title, systemImage: a.symbol) { model.askClaude(action: a) }
                    }
                }
            }
        }
        .fixedSize()
        .readerOverlay()
    }

    private func labeledButton(_ symbol: String, _ title: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(role == .destructive ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                .padding(.horizontal, 9)
                .frame(height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct FootnoteCard: View {
    let note: FootnotePopup
    let theme: ReaderTheme
    let open: (() -> Void)?
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Note", systemImage: "text.append").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let open {
                    Button("Go to Note", action: open).buttonStyle(.borderless).font(.caption.weight(.medium))
                }
                Button(action: dismiss) { Image(systemName: "xmark").font(.caption.weight(.bold)) }.buttonStyle(.borderless)
            }
            let text = Text(note.text)
                .font(.system(size: 14, design: .serif))
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if note.text.count > 420 {
                ScrollView { text }.frame(height: 180)
            } else {
                text.fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 360)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .readerOverlay()
        .shadow(color: .black.opacity(0.12), radius: 20, y: 8)
    }
}

private struct NoteEditor: View {
    let highlight: Highlight
    let save: (String) -> Void
    @State private var text: String
    @Environment(\.dismiss) private var dismiss

    init(highlight: Highlight, save: @escaping (String) -> Void) {
        self.highlight = highlight
        self.save = save
        _text = State(initialValue: highlight.note ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(highlight.color.color).frame(width: 4)
                Text(highlight.text).font(.system(.body, design: .serif).italic()).lineLimit(5).foregroundStyle(.secondary)
            }
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
                .frame(minHeight: 140)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save(text); dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.glassProminent)
            }
        }
        .padding(22)
        .frame(width: 460)
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
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let button = window.standardWindowButton(type) else { continue }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.35
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
        private weak var window: NSWindow?
        private var monitor: Any?
        private var observers: [NSObjectProtocol] = []

        init(model: ReaderModel) { self.model = model }

        func attach(_ window: NSWindow) {
            guard self.window !== window else { return }
            detach()
            self.window = window
            window.styleMask.insert(.fullSizeContentView)
            window.acceptsMouseMovedEvents = true
            model.isFullScreen = window.styleMask.contains(.fullScreen)
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .mouseMoved]) { [weak self] event in
                guard let self, let window = self.window, event.window === window, window.isKeyWindow else { return event }
                if event.type == .mouseMoved {
                    if self.model.isFullScreen { self.model.pokeChrome() }
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
