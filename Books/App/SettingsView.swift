import AppKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            ReadingSettingsTab().tabItem { Label("Reading", systemImage: "textformat.size") }
            ClaudeSettings().tabItem { Label("Claude", systemImage: "sparkles") }
        }
        .frame(width: 500)
    }
}

private struct GeneralSettings: View {
    @AppStorage("autoCopyOpenedBooks") private var autoCopy = true
    @State private var status: String?
    @State private var library = LibraryStore.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Location") {
                    HStack(spacing: 8) {
                        Text(locationLabel)
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                            .help(library.rootURL.path)
                        Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([library.rootURL]) }
                            .controlSize(.small)
                    }
                }
                Toggle("Copy opened books into the library", isOn: $autoCopy)
            } header: {
                Text("Library")
            } footer: {
                Text(library.usesICloud
                     ? "Books, positions, highlights, notes, Claude conversations and settings sync through iCloud Drive."
                     : "Turn on iCloud Drive to sync your library across Macs.")
                    .formFooterStyle()
            }
            Section {
                LabeledContent("Make Books the default for") {
                    HStack(spacing: 8) {
                        Button("eBooks") { Task { status = await AppActions.makeDefaultReader() } }
                        Button("PDFs") { Task { status = await AppActions.makeDefaultPDFReader() } }
                    }
                }
            } header: {
                Text("Default App")
            } footer: {
                Text(status ?? "eBooks covers EPUB, MOBI, AZW3, FB2 and comic archives.")
                    .formFooterStyle()
            }
        }
        .settingsTab()
    }

    private var locationLabel: String {
        library.usesICloud ? "iCloud Drive › Books" : library.rootURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

private struct ReadingSettingsTab: View {
    var body: some View {
        ReaderSettingsPopover(kind: .reflowable)
            .frame(maxWidth: .infinity)
    }
}

private struct ClaudeSettings: View {
    @AppStorage("claudePath") private var path = ""
    @AppStorage("claudeModel") private var model = ClaudeModel.sonnet.rawValue
    @AppStorage("claudeEffort") private var effort = ClaudeEffort.low.rawValue
    @AppStorage(ChatFont.key) private var chatFont = ChatFont.charter
    @AppStorage(ChatTextSize.key) private var chatTextSize = ChatTextSize.standard
    @State private var detected: String?
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Claude Code") {
                    HStack(spacing: 8) {
                        Text(testResult ?? detected.map { $0.replacingOccurrences(of: NSHomeDirectory(), with: "~") } ?? "Not found")
                            .foregroundStyle(detected == nil ? .red : .secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Button(testing ? "Testing…" : "Test") { test() }.disabled(testing || detected == nil)
                    }
                }
                TextField("Custom path", text: $path, prompt: Text("Auto-detect"))
            } header: {
                Text("Connection")
            } footer: {
                Text("Uses your Claude subscription through Claude Code. Run `claude` in Terminal once to sign in.")
                    .formFooterStyle()
            }
            Section("Defaults") {
                Picker("Model", selection: $model) {
                    ForEach(ClaudeModel.allCases) { Text($0.name).tag($0.rawValue) }
                }
                Picker("Effort", selection: $effort) {
                    ForEach(ClaudeEffort.allCases) { Text($0.name).tag($0.rawValue) }
                }
            }
            Section {
                Picker("Font", selection: $chatFont) {
                    ForEach(ChatFont.allCases) { Text($0.name).tag($0) }
                }
                Picker("Text size", selection: $chatTextSize) {
                    ForEach(ChatTextSize.options, id: \.size) { Text($0.name).tag($0.size) }
                }
            } header: {
                Text("Chat")
            } footer: {
                Text("The quick brown fox jumps over the lazy dog.")
                    .font(chatFont.font(chatTextSize))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .settingsTab()
        .task { detected = await Task.detached { ClaudeService.executable()?.path }.value }
        .onChange(of: path) { _, _ in
            testResult = nil
            Task { detected = await Task.detached { ClaudeService.executable()?.path }.value }
        }
    }

    private func test() {
        testing = true
        testResult = nil
        Task {
            var text = ""
            do {
                for try await event in ClaudeService.stream(prompt: "Reply with exactly: Ready to read.", system: "You are a test.", model: .haiku, effort: .low) {
                    if case .text(let t) = event { text += t }
                }
                testResult = "✓ " + text.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                testResult = error.localizedDescription
            }
            testing = false
        }
    }
}

private extension View {
    func formFooterStyle() -> some View {
        font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Grouped form sized to its content, so the window fits each tab.
    func settingsTab() -> some View {
        formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 20)
    }
}
