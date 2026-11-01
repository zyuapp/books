import AppKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            ReadingSettingsTab().tabItem { Label("Reading", systemImage: "textformat.size") }
            ClaudeSettings().tabItem { Label("Claude", systemImage: "sparkles") }
        }
        .frame(width: 520)
        .scenePadding()
    }
}

private struct GeneralSettings: View {
    @AppStorage("autoCopyOpenedBooks") private var autoCopy = true
    @State private var status: String?
    @State private var library = LibraryStore.shared

    var body: some View {
        Form {
            Section("Library") {
                LabeledContent("Location") {
                    HStack {
                        Text(library.rootURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([library.rootURL]) }
                    }
                }
                Toggle("Copy books opened from Finder into the iCloud library", isOn: $autoCopy)
                Text("Reading positions, highlights, notes and Claude conversations sync through iCloud Drive for every book, even ones that stay where they are. PDFs and plain documents are read in place.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Default App") {
                HStack {
                    Button("Make Books the Default for eBooks") {
                        Task { status = await AppActions.makeDefaultReader() }
                    }
                    Button("Also Open PDFs") {
                        Task { status = await AppActions.makeDefaultPDFReader() }
                    }
                }
                Text("Covers EPUB, MOBI, AZW3, FB2 and comic archives (CBZ, CBR, CB7, CBT). You can also choose Books in Finder › Get Info › Open with › Change All.")
                    .font(.caption).foregroundStyle(.secondary)
                if let status { Text(status).font(.callout) }
            }
        }
        .formStyle(.grouped)
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
    @State private var detected: String?
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Claude Code") {
                    Text(detected ?? "Not found").foregroundStyle(detected == nil ? .red : .secondary)
                        .font(.callout).lineLimit(1).truncationMode(.middle)
                }
                TextField("Custom path", text: $path, prompt: Text("Auto-detect"))
                Picker("Default model", selection: $model) {
                    ForEach(ClaudeModel.allCases) { Text($0.name).tag($0.rawValue) }
                }
                HStack {
                    Button(testing ? "Testing…" : "Test Connection") { test() }.disabled(testing)
                    if let testResult { Text(testResult).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
                }
            } footer: {
                Text("Books asks Claude through your installed Claude Code CLI, so it uses your Claude subscription. Run `claude` once in Terminal and sign in if you haven’t.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { detected = await Task.detached { ClaudeService.executable()?.path }.value }
        .onChange(of: path) { _, _ in Task { detected = await Task.detached { ClaudeService.executable()?.path }.value } }
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
