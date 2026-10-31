import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct BooksApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Books", id: "library") {
            RootView()
                .frame(minWidth: 820, minHeight: 560)
        }
        .defaultSize(width: 1220, height: 800)
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
        Task { @MainActor in LibraryStore.shared.start() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            LibraryStore.shared.start()
            for url in urls { AppActions.open(url) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { LibraryStore.shared.flushAll() }
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

    private init() {
        bookID = UserDefaults.standard.string(forKey: "openBookID")
    }
}

/// Lets AppKit entry points (Finder opens, Dock reopen) show the main window.
@MainActor
final class OpenBridge {
    static let shared = OpenBridge()
    private var openWindow: OpenWindowAction?

    func attach(_ action: OpenWindowAction) { openWindow = action }

    func openBook(_ id: String) {
        withAnimation(.smooth(duration: 0.35)) { AppNavigation.shared.bookID = id }
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
        LibraryStore.shared.flushAll()
        withAnimation(.smooth(duration: 0.35)) { AppNavigation.shared.bookID = nil }
    }
}

/// The main window: the library, or the book being read.
struct RootView: View {
    @State private var nav = AppNavigation.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack {
            if let id = nav.bookID {
                ReaderWindow(bookID: id)
                    .id(id)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                LibraryView()
                    .transition(.opacity)
            }
        }
        .onAppear {
            LibraryStore.shared.start()
            OpenBridge.shared.attach(openWindow)
        }
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
        panel.message = "Books are copied into iCloud Drive › Books"
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
        CommandGroup(replacing: .newItem) {
            Button("Open…") { AppActions.openFiles() }.keyboardShortcut("o")
            Button("Add to Library…") { AppActions.addBooks() }.keyboardShortcut("o", modifiers: [.command, .shift])
            Divider()
            Button("Show Library") { OpenBridge.shared.showLibrary(); OpenBridge.shared.openLibrary() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
        }
        CommandMenu("Go") {
            Button("Next Page") { reader?.nextPage() }.disabled(reader == nil)
            Button("Previous Page") { reader?.previousPage() }.disabled(reader == nil)
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
            Button("Find in Book") { toggle(.search) }.keyboardShortcut("f")
                .disabled(reader == nil)
        }
        CommandMenu("Book") {
            Button("Add Bookmark") { reader?.toggleBookmark() }.keyboardShortcut("d")
                .disabled(reader == nil)
            Button("Ask Claude") {
                guard let reader else { return }
                if reader.showClaude && reader.selection == nil { reader.showClaude = false } else { reader.askClaude(action: nil) }
            }
            .keyboardShortcut("l")
            .disabled(reader == nil)
            Menu("Ask Claude to…") {
                ForEach(ClaudeQuickAction.allCases) { a in
                    Button(a.title) { reader?.askClaude(action: a) }
                }
            }
            .disabled(reader == nil)
            Divider()
            Button("Reading Settings") { reader?.showSettings.toggle() }.keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(reader == nil)
            Button("Bigger Text") { ReaderSettings.shared.prefs.fontSize = min(40, ReaderSettings.shared.prefs.fontSize + 1) }
                .keyboardShortcut("=")
            Button("Smaller Text") { ReaderSettings.shared.prefs.fontSize = max(12, ReaderSettings.shared.prefs.fontSize - 1) }
                .keyboardShortcut("-")
        }
    }

    private func toggle(_ panel: ReaderPanel) {
        guard let reader else { return }
        withAnimation(.spring(duration: 0.4)) { reader.panel = reader.panel == panel ? nil : panel }
    }
}
