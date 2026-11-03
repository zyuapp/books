import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct BooksApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() { LegacyDefaults.migrate() }

    var body: some Scene {
        Window("Books", id: "library") {
            RootView()
                .frame(minWidth: 820, minHeight: 560)
        }
        .defaultSize(width: 1220, height: 800)
        // Each screen draws its own `HeaderBar` where the title bar would be; the window keeps one shape for both.
        .windowStyle(.hiddenTitleBar)
        .commands { BooksCommands() }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Writing a large prompt to a Claude process that already exited must not kill the app.
        signal(SIGPIPE, SIG_IGN)
        Task { @MainActor in
            LibraryStore.shared.start()
            Updater.shared.start()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            LibraryStore.shared.start()
            for url in urls { AppActions.open(url) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            LibraryStore.shared.flushAll()
            Updater.shared.installOnQuit()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { OpenBridge.shared.openLibrary() } }
        return true
    }
}

/// Which book (if any) the main window is showing.
@MainActor @Observable
final class AppNavigation {
    static let shared = AppNavigation()

    var bookID: String? {
        didSet { UserDefaults.standard.set(bookID, forKey: "openBookID") }
    }
    /// True once a book has fully faded in over the library.
    private(set) var libraryCovered: Bool
    @ObservationIgnored private var switchTask: Task<Void, Never>?

    private init() {
        let saved = UserDefaults.standard.string(forKey: "openBookID")
        bookID = saved
        libraryCovered = saved != nil
    }

    func switchScreen(to id: String?) {
        libraryCovered = false
        var transaction = Transaction(animation: Motion.screenFade)
        transaction[SwitchingScreen.self] = true
        withTransaction(transaction) { bookID = id }
        switchTask?.cancel()
        switchTask = Task {
            try? await Task.sleep(for: .seconds(Motion.screenFadeDuration))
            guard !Task.isCancelled else { return }
            libraryCovered = bookID != nil
            switchTask = nil
        }
    }

    /// Returns once the current screen switch has finished fading.
    func settled() async {
        await switchTask?.value
    }
}

/// Lets AppKit entry points (Finder opens, Dock reopen) show the main window.
@MainActor
final class OpenBridge {
    static let shared = OpenBridge()
    private var openWindow: OpenWindowAction?

    func attach(_ action: OpenWindowAction) { openWindow = action }

    func openBook(_ id: String) {
        AppNavigation.shared.switchScreen(to: id)
        openLibrary()
    }

    func openLibrary() {
        if NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
            NSApp.windows.first { $0.isVisible && $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        } else {
            openWindow?(id: "library")
        }
        NSApp.activate()
    }

    func showLibrary() {
        LibraryStore.shared.saveAllInBackground()
        AppNavigation.shared.switchScreen(to: nil)
    }
}

/// Marks the cross-fade between the library and a book, so layout inside each side doesn't animate with it.
private struct SwitchingScreen: TransactionKey {
    static let defaultValue = false
}

/// The main window: the library, or the book being read.
struct RootView: View {
    @State private var nav = AppNavigation.shared
    @State private var settings = ReaderSettings.shared
    @Environment(\.openWindow) private var openWindow

    @State private var system = SystemAppearance.shared

    private var readerScheme: ColorScheme {
        let theme = settings.prefs.theme
        if theme != .auto { return theme.isDark ? .dark : .light }
        return system.isDark ? .dark : .light
    }

    /// Changes only while the library is out of sight, so it never visibly flips. Always explicit: SwiftUI keeps the
    /// last scheme it was given when handed `nil`.
    private var windowScheme: ColorScheme {
        nav.libraryCovered ? readerScheme : (system.isDark ? .dark : .light)
    }

    var body: some View {
        // The library stays underneath and the opaque reader fades over it; the library itself never fades.
        ZStack {
            LibraryView()
                .allowsHitTesting(nav.bookID == nil)
                .accessibilityHidden(nav.bookID != nil)
                .opacity(nav.libraryCovered ? 0 : 1)
                .transaction(value: nav.libraryCovered) { $0.animation = nil }
            if let id = nav.bookID {
                ReaderWindow(bookID: id)
                    .id(id)
                    .environment(\.colorScheme, readerScheme)
                    .transaction { if $0[SwitchingScreen.self] { $0.animation = nil } }
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .onAppear {
            LibraryStore.shared.start()
            OpenBridge.shared.attach(openWindow)
        }
        .preferredColorScheme(windowScheme)
        .background(MainWindowSetup())
        // SwiftUI routes Finder "Open" events here once a window exists.
        .onOpenURL { url in
            if url.isFileURL { AppActions.open(url) }
        }
    }
}

@MainActor
enum AppActions {
    static func open(_ url: URL) {
        Task {
            await LibraryStore.shared.waitUntilReady()
            guard let record = LibraryStore.shared.recordForOpening(url) else { return }
            OpenBridge.shared.openBook(record.id)
        }
    }

    static var contentTypes: [UTType] {
        BookFormat.fileExtensions.compactMap { UTType(filenameExtension: $0) }
    }

    static func openFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = contentTypes
        panel.message = "Choose books to read"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { open(url) }
    }

    static func addBooks() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = contentTypes
        panel.prompt = "Add to Library"
        panel.message = LibraryStore.shared.usesICloud ? "Books are copied into iCloud Drive › Books" : "Books are copied into your library"
        guard panel.runModal() == .OK else { return }
        var files: [URL] = []
        for url in panel.urls {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                files += Archive.files(in: url).filter { BookFormat(url: $0) != nil }
            } else {
                files.append(url)
            }
        }
        LibraryStore.shared.importBooks(files)
    }

    /// Registers Books as the default app for every format it reads.
    static func makeDefaultReader() async -> String {
        let app = Bundle.main.bundleURL
        var done = 0
        var failures: [String] = []
        let types = Set(contentTypes).filter { t in
            // Leave everyday document types to their usual apps.
            ![UTType.plainText, .html, .rtf, .pdf].contains(t) && !t.conforms(to: .plainText)
        }
        for type in types {
            do {
                try await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type)
                done += 1
            } catch {
                failures.append(type.preferredFilenameExtension ?? type.identifier)
            }
        }
        return failures.isEmpty ? "Books now opens \(done) book formats." : "Set \(done) formats. Couldn’t set: \(failures.joined(separator: ", "))."
    }

    static func makeDefaultPDFReader() async -> String {
        do {
            try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: .pdf)
            return "Books now opens PDFs."
        } catch {
            return error.localizedDescription
        }
    }
}

struct BooksCommands: Commands {
    @FocusedValue(\.readerModel) private var reader

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { Task { await Updater.shared.check(interactive: true) } }
        }
        CommandGroup(before: .windowSize) {
            Button("Toggle Full Screen") {
                (NSApp.keyWindow ?? NSApp.mainWindow)?.toggleFullScreen(nil)
            }
            .keyboardShortcut("f", modifiers: [.command, .control])
        }
        CommandGroup(replacing: .newItem) {
            Button("Open…") { AppActions.openFiles() }.keyboardShortcut("o")
            Button("Add to Library…") { AppActions.addBooks() }.keyboardShortcut("o", modifiers: [.command, .shift])
            Divider()
            Button("Show Library") { OpenBridge.shared.showLibrary(); OpenBridge.shared.openLibrary() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Close Book  ⌘W") { OpenBridge.shared.showLibrary() }
                .disabled(reader == nil)
        }
        CommandMenu("Go") {
            Button("Next Page  →") { reader?.nextPage() }.disabled(reader == nil)
            Button("Previous Page  ←") { reader?.previousPage() }.disabled(reader == nil)
            Button("Next Chapter  ⌥→") { reader?.goToChapter(offset: 1) }.disabled(reader == nil)
            Button("Previous Chapter  ⌥←") { reader?.goToChapter(offset: -1) }.disabled(reader == nil)
            Button("Beginning of Book") { reader?.goToStart() }.disabled(reader == nil)
            Divider()
            Button("Undo Jump — Back to Previous Location") { reader?.goBack() }.keyboardShortcut("[")
                .disabled(reader?.canGoBack != true)
            Button("Forward") { reader?.goForward() }.keyboardShortcut("]")
                .disabled(reader?.canGoForward != true)
            Divider()
            Button("Contents") { toggle(.contents) }.keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(reader == nil)
            Button("Highlights & Bookmarks") { toggle(.notes) }.keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(reader == nil)
            Button(reader == nil ? "Find in Library" : "Find in Book") {
                if reader != nil { toggle(.search) } else { LibrarySearchFocus.shared.requested += 1 }
            }
            .keyboardShortcut("f")
        }
        CommandMenu("Book") {
            Button("Add Bookmark") { reader?.toggleBookmark() }.keyboardShortcut("d")
                .disabled(reader == nil)
            Button("Ask Claude") {
                guard let reader else { return }
                if reader.showClaude && reader.selection == nil && reader.claudeInputFocused {
                    withAnimation(Motion.panel) { reader.showClaude = false }
                    reader.engine?.focusContent()
                } else {
                    reader.askClaude(action: nil)
                }
            }
            .keyboardShortcut("l")
            .disabled(reader == nil)
            Button("New Claude Chat") { reader?.newClaudeChat() }
                .keyboardShortcut("n")
                .disabled(reader == nil)
            Menu("Ask Claude to…") {
                ForEach(ClaudeQuickAction.allCases) { a in
                    Button(a.title) { reader?.askClaude(action: a) }
                }
            }
            .disabled(reader == nil)
            Divider()
            Button("Reading Settings") { reader?.showSettings.toggle() }.keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(reader == nil)
            Button(isPDF ? "Zoom In" : "Bigger Text") {
                if isPDF { reader?.engine?.zoom(by: 1) } else { ReaderSettings.shared.prefs.fontSize = min(40, ReaderSettings.shared.prefs.fontSize + 1) }
            }
            .keyboardShortcut("=")
            Button(isPDF ? "Zoom Out" : "Smaller Text") {
                if isPDF { reader?.engine?.zoom(by: -1) } else { ReaderSettings.shared.prefs.fontSize = max(12, ReaderSettings.shared.prefs.fontSize - 1) }
            }
            .keyboardShortcut("-")
            Button(isPDF ? "Fit to Window" : "Default Text Size") {
                if isPDF { reader?.engine?.zoom(by: 0) } else { ReaderSettings.shared.prefs.fontSize = ReaderPreferences().fontSize }
            }
            .keyboardShortcut("0")
        }
    }

    private var isPDF: Bool { reader?.publication?.kind == .pdf }

    private func toggle(_ panel: ReaderPanel) {
        guard let reader else { return }
        withAnimation(Motion.panel) { reader.panel = reader.panel == panel ? nil : panel }
    }
}

/// The system appearance, as a value views can watch.
@MainActor @Observable
final class SystemAppearance {
    static let shared = SystemAppearance()
    private(set) var isDark: Bool
    @ObservationIgnored private var observation: NSKeyValueObservation?

    private init() {
        isDark = Self.current
        observation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.isDark = Self.current }
        }
    }

    private static var current: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

/// Lets the main window enter full screen (SwiftUI `Window` scenes don't opt in by default) and move by its background.
private struct MainWindowSetup: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        configure(view.window)
    }
    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isMovableByWindowBackground = true
        // Keyboard focus starts on nothing rather than on the library's search field.
        if window.firstResponder is NSTextView, !window.isKeyWindow { window.makeFirstResponder(nil) }
    }
}

/// Bumped by ⌘F in the library so the search field takes focus.
@MainActor @Observable
final class LibrarySearchFocus {
    static let shared = LibrarySearchFocus()
    var requested = 0
}

/// Carries settings over from the pre-release bundle identifier, once.
enum LegacyDefaults {
    static func migrate() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedLegacyDefaults") else { return }
        defaults.set(true, forKey: "migratedLegacyDefaults")
        guard let old = UserDefaults(suiteName: "com.zyuapp.books")?.dictionaryRepresentation() else { return }
        let keys = ["readerPreferences", "librarySort", "coverSize", "claudeModel", "claudePath", "autoCopyOpenedBooks", "externalBookPaths"]
        for key in keys where defaults.object(forKey: key) == nil {
            if let value = old[key] { defaults.set(value, forKey: key) }
        }
    }
}
