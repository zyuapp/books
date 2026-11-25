import AppKit
import SwiftUI

struct SettingsView: View {
    private enum Tab: String, CaseIterable {
        case general = "General", reading = "Reading", chatGPT = "ChatGPT"
        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .reading: "textformat.size"
            case .chatGPT: "sparkles"
            }
        }
    }

    @State private var tab = Tab.general

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(Tab.allCases, id: \.self) { item in
                    let selected = item == tab
                    Button { tab = item } label: {
                        VStack(spacing: 3) {
                            Image(systemName: item.symbol).font(.system(size: 17)).frame(height: 20)
                            Text(item.rawValue).font(.callout)
                        }
                        .foregroundStyle(selected ? Color.brand : Color.secondary)
                        .frame(width: 72, height: 48)
                        .background(.primary.opacity(selected ? 0.07 : 0), in: .rect(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.vertical, 8)
            Divider()
            switch tab {
            case .general: GeneralSettings()
            case .reading: ReadingSettingsTab()
            case .chatGPT: ChatGPTSettings()
            }
        }
        .frame(width: 500)
        .navigationTitle(tab.rawValue)
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
                Toggle("Copy opened books into the library", isOn: $autoCopy).tint(Color.brand)
            } header: {
                Text("Library")
            } footer: {
                Text(library.usesICloud
                     ? "Books, positions, highlights, notes, ChatGPT conversations and settings sync through iCloud Drive."
                     : "Turn on iCloud Drive to sync your library across Macs.")
                    .formFooterStyle()
            }
            Section {
                LabeledContent("Make Page Owl the default for") {
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
        library.usesICloud ? "iCloud Drive › Page Owl" : library.rootURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

private struct ReadingSettingsTab: View {
    @State private var settings = ReaderSettings.shared

    var body: some View {
        @Bindable var s = settings
        Form {
            Section("Theme") {
                ThemeGrid().padding(.vertical, 4)
            }
            Section("Text") {
                Picker("Font", selection: $s.prefs.fontID) {
                    ForEach(ReaderFont.all) { Text($0.name).tag($0.id) }
                }
                LabeledContent("Size") {
                    HStack(spacing: 8) {
                        Text("\(Int(s.prefs.fontSize)) pt").monospacedDigit()
                        Stepper("Size", value: $s.prefs.fontSize, in: 12...40).labelsHidden()
                    }
                }
                LabeledContent("Spacing") {
                    HStack(spacing: 8) {
                        Slider(value: $s.prefs.lineHeight, in: 1.1...2.2).labelsHidden().frame(width: 180).tint(Color.brand)
                        Text(String(format: "%.2f×", s.prefs.lineHeight)).monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                LabeledContent("Margins") {
                    HStack(spacing: 8) {
                        Slider(value: $s.prefs.margin, in: 16...140).labelsHidden().frame(width: 180).tint(Color.brand)
                        Text("\(Int(s.prefs.margin)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Toggle("Justify", isOn: $s.prefs.justify).tint(Color.brand)
                Toggle("Hyphenate", isOn: $s.prefs.hyphenate).tint(Color.brand)
            }
            Section("Layout") {
                LabeledContent("Layout") {
                    PillPicker(selection: $s.prefs.layout, options: PageLayout.allCases.map { ($0, $0.name) }).frame(width: 230)
                }
                LabeledContent("Pages") {
                    PillPicker(selection: $s.prefs.spread, options: SpreadMode.allCases.map { ($0, $0.name) }).frame(width: 230)
                }
            }
        }
        .settingsTab()
    }
}

private struct ChatGPTSettings: View {
    @AppStorage(ChatSettings.modelKey) private var model = ChatGPTModel.fallback.slug
    @AppStorage(ChatSettings.effortKey) private var effort = "low"
    @AppStorage(ChatFont.key) private var chatFont = ChatFont.standard
    @AppStorage(ChatTextSize.key) private var chatTextSize = ChatTextSize.standard
    @State private var signOutNote: String?
    private var account: ChatGPTAccount { .shared }

    var body: some View {
        Form {
            Section {
                switch account.status {
                case .signedIn:
                    LabeledContent("Account") {
                        HStack(spacing: 8) {
                            Text(account.email ?? "Signed in").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Button("Sign Out") { signOut() }
                        }
                    }
                    LabeledContent("Usage") {
                        Button("Manage Usage") { NSWorkspace.shared.open(ChatGPTAccount.usageURL) }
                    }
                case .signingIn:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Finish signing in in your browser…").foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { account.cancelSignIn() }
                    }
                case .signedOut:
                    HStack(spacing: 10) {
                        ContinueWithChatGPTButton { account.signIn() }
                        if account.hasSavedAccount {
                            Button("Use Another Account") { account.signIn(anotherAccount: true) }
                                .buttonStyle(.link)
                        }
                    }
                }
                if let problem = account.problem, account.status != .signingIn {
                    Text(problem).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if let signOutNote {
                    Text(signOutNote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Use your ChatGPT plan")
            } footer: {
                Text("Questions you ask in Page Owl use your ChatGPT Plus or Pro plan. Review and limit Page Owl’s usage in ChatGPT settings.")
                    .formFooterStyle()
            }
            Section("Defaults") {
                Picker("Model", selection: $model) {
                    ForEach(ChatSettings.models) { Text($0.name).tag($0.slug) }
                }
                let efforts = ChatSettings.model(model).efforts
                if !efforts.isEmpty {
                    Picker("Effort", selection: Binding(get: { ChatSettings.resolve(model: model, effort: effort).effort },
                                                        set: { effort = $0 })) {
                        ForEach(efforts, id: \.self) { Text(ChatGPTModel.effortName($0)).tag($0) }
                    }
                }
            }
            Section("Chat") {
                Picker("Font", selection: $chatFont) {
                    ForEach(ChatFont.allCases) { Text($0.name).tag($0) }
                }
                Picker("Text size", selection: $chatTextSize) {
                    ForEach(ChatTextSize.options, id: \.size) { Text($0.name).tag($0.size) }
                }
                Text("The quick brown fox jumps over the lazy dog.")
                    .font(chatFont.font(chatTextSize))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .settingsTab()
        .task { if account.status == .signedIn { await account.loadModels() } }
    }

    private func signOut() {
        signOutNote = nil
        Task {
            if !(await account.signOut()) {
                signOutNote = "Signed out on this Mac, but OpenAI didn’t confirm it. You can disconnect Page Owl in ChatGPT settings."
            }
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
