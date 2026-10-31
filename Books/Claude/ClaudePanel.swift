import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class ClaudeChat {
    var thread: ChatThread?
    var input = ""
    var streamingText = ""
    var isStreaming = false
    var error: String?
    var scope: ClaudeScope = .chapter
    /// What a running tool is doing, e.g. "Reading your highlights".
    var toolProgress: String?
    /// Changes Claude made this session, kept so they can be undone. `messageID` is nil while the answer streams.
    var activities: [ChatActivity] = []
    /// Undos since the last question, so Claude knows its change was reverted on purpose.
    @ObservationIgnored private var undoneSinceLastSend: [String] = []
    var model: ClaudeModel {
        didSet { UserDefaults.standard.set(model.rawValue, forKey: "claudeModel") }
    }

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private weak var reader: ReaderModel?

    init(reader: ReaderModel) {
        self.reader = reader
        model = ClaudeModel(rawValue: UserDefaults.standard.string(forKey: "claudeModel") ?? "") ?? .sonnet
    }

    func begin(with seed: ClaudeRequestSeed) {
        cancel()
        thread = ChatThread(title: seed.passage.map { String($0.prefix(60)) } ?? (reader?.chapterTitle ?? "Question"),
                            passage: seed.passage, locator: seed.locator, scope: seed.passage == nil ? .chapter : scope)
        scope = thread?.scope ?? .chapter
        if seed.passage != nil && scope == .passage { scope = .chapter }
        error = nil
        if let action = seed.action { send(action.prompt(hasPassage: seed.passage != nil)) }
    }

    func newThread() {
        cancel()
        thread = nil
        error = nil
        input = ""
    }

    func open(_ t: ChatThread) {
        cancel()
        thread = t
        scope = t.scope
        error = nil
    }

    func cancel() {
        task?.cancel()
        task = nil
        if isStreaming, !streamingText.isEmpty { appendAssistant(streamingText + " …") }
        isStreaming = false
        streamingText = ""
    }

    func send(_ text: String? = nil) {
        let question = (text ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isStreaming, let reader else { return }
        input = ""
        error = nil
        if thread == nil {
            thread = ChatThread(title: String(question.prefix(60)), passage: nil, locator: reader.location, scope: scope)
        }
        thread!.scope = scope
        let history = thread!.messages
        thread!.messages.append(ChatMessage(role: .user, text: question))
        thread!.updated = Date()
        persist()

        isStreaming = true
        streamingText = ""
        let passage = thread!.passage
        let undone = undoneSinceLastSend
        undoneSinceLastSend = []
        let scope = scope
        let model = model
        task = Task {
            let context = await reader.context(for: scope)
            let system = Self.systemPrompt(reader: reader)
            var prompt = Self.prompt(context: context, scope: scope, passage: passage, history: history, question: question)
            if !undone.isEmpty {
                prompt = "<app_events>\nThe reader pressed Undo on: " + undone.joined(separator: "; ") + "\n</app_events>\n\n" + prompt
            }
            let session = AgentSession(reader: reader)
            session.onActivity = { [weak self] activity in
                withAnimation(.snappy) { self?.activities.append(ChatActivity(activity: activity)) }
            }
            session.onProgress = { [weak self] label in
                withAnimation(.easeOut(duration: 0.2)) { self?.toolProgress = label }
            }
            let access = await LocalToolServer.shared.register(session)
            defer {
                if let token = access?.token { LocalToolServer.shared.unregister(token) }
                toolProgress = nil
            }
            do {
                for try await event in ClaudeService.stream(prompt: prompt, system: system, model: model, toolsConfig: access?.config) {
                    if Task.isCancelled { break }
                    if case .text(let t) = event { streamingText += t }
                }
                guard !Task.isCancelled else { return }
                appendAssistant(streamingText)
            } catch {
                guard !Task.isCancelled else { return }
                if !streamingText.isEmpty { appendAssistant(streamingText) }
                self.error = error.localizedDescription
            }
            isStreaming = false
            streamingText = ""
        }
    }

    private func appendAssistant(_ text: String) {
        let pending = activities.indices.filter { activities[$0].messageID == nil }
        guard thread != nil, !text.isEmpty || !pending.isEmpty else { return }
        var message = ChatMessage(role: .assistant, text: text.isEmpty ? "Done." : text)
        if !pending.isEmpty { message.actions = pending.map { activities[$0].activity.title } }
        for i in pending { activities[i].messageID = message.id }
        thread!.messages.append(message)
        thread!.updated = Date()
        persist()
    }

    private func persist() {
        guard let thread, let reader else { return }
        reader.library.update(reader.book.id) { s in
            if let i = s.chats.firstIndex(where: { $0.id == thread.id }) { s.chats[i] = thread } else { s.chats.append(thread) }
        }
    }

    func undo(_ id: UUID) {
        guard let i = activities.firstIndex(where: { $0.id == id }), !activities[i].undone else { return }
        activities[i].activity.undo?()
        undoneSinceLastSend.append(activities[i].activity.title)
        withAnimation(.snappy) { activities[i].undone = true }
    }

    func delete(_ t: ChatThread) {
        guard let reader else { return }
        reader.library.update(reader.book.id) { s in
            if let i = s.chats.firstIndex(where: { $0.id == t.id }) {
                s.chats[i].deleted = true
                s.chats[i].updated = Date()
            }
        }
        if thread?.id == t.id { thread = nil }
    }

    private static func systemPrompt(reader: ReaderModel) -> String {
        let author = reader.publication?.author ?? reader.state.author
        let pct = Int((reader.location.totalProgress * 100).rounded())
        let where_ = [reader.chapterTitle, "\(pct)% through the book"].compactMap { $0 }.joined(separator: ", ")
        return """
        You are a warm, perceptive reading companion built into a book reader app. The reader is reading \
        “\(reader.title)”\(author.map { " by \($0)" } ?? ""). They are currently at: \(where_).
        Answer from the provided book text when it's relevant, and from your own knowledge otherwise. \
        Be concise and specific: short paragraphs, quotes from the text when helpful, light Markdown (bold, italics, short lists). \
        Never reveal plot developments beyond the reader's current position unless they explicitly ask for spoilers.
        \(AgentToolbox.guidance)
        """
    }

    private static func prompt(context: String, scope: ClaudeScope, passage: String?, history: [ChatMessage], question: String) -> String {
        var parts: [String] = []
        let limit = scope == .book ? 600_000 : 150_000
        if !context.isEmpty {
            let clipped = context.count > limit ? String(context.prefix(limit)) + "\n[…truncated…]" : context
            parts.append("<book_text scope=\"\(scope.rawValue)\">\n\(clipped)\n</book_text>")
        }
        if let passage { parts.append("<selected_passage>\n\(passage)\n</selected_passage>") }
        if !history.isEmpty {
            let convo = history.map { "\($0.role == .user ? "Reader" : "You"): \($0.text)" }.joined(separator: "\n\n")
            parts.append("<conversation_so_far>\n\(convo)\n</conversation_so_far>")
        }
        parts.append(question)
        return parts.joined(separator: "\n\n")
    }
}

struct ChatActivity: Identifiable {
    let id = UUID()
    var activity: AgentActivity
    var messageID: UUID?
    var undone = false
}

struct ClaudePanel: View {
    let reader: ReaderModel
    @Bindable var chat: ClaudeChat
    let theme: ReaderTheme
    @FocusState private var inputFocused: Bool

    private static let accent = Color(hex: "#C96442")

    var body: some View {
        ZStack {
            if reader.claudeShowsHistory {
                history
                    .transition(.move(edge: .leading).combined(with: .opacity))
            } else {
                VStack(spacing: 0) {
                    header
                    Divider().opacity(0.35)
                    conversation
                    composer
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.3), value: reader.claudeShowsHistory)
        .frame(width: 400)
        .glassEffect(.regular.tint(theme.backgroundColor.opacity(0.6)), in: .rect(cornerRadius: 26))
        .clipShape(.rect(cornerRadius: 26))
        .readerOverlay()
        .shadow(color: .black.opacity(0.14), radius: 30, y: 10)
        .onChange(of: reader.claudeDraft) { _, seed in
            if let seed { chat.begin(with: seed); reader.claudeShowsHistory = false; reader.claudeDraft = nil; inputFocused = true }
        }
        .onAppear {
            if let seed = reader.claudeDraft { chat.begin(with: seed); reader.claudeDraft = nil }
            inputFocused = true
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            ClaudeAvatar(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Claude").font(.system(size: 14, weight: .semibold))
                Text(chat.thread?.messages.isEmpty == false ? (chat.thread?.title ?? "") : "Reading companion")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            PanelIconButton(symbol: "clock.arrow.circlepath", label: "Conversations",
                            badge: reader.state.liveChats.count) { reader.claudeShowsHistory = true }
            PanelIconButton(symbol: "square.and.pencil", label: "New Conversation") {
                chat.newThread()
                inputFocused = true
            }
            PanelIconButton(symbol: "xmark", label: "Close") {
                withAnimation(.spring(duration: 0.35)) { reader.showClaude = false }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let passage = chat.thread?.passage {
                        PassageCard(text: passage)
                    }
                    if chat.thread?.messages.isEmpty ?? true, !chat.isStreaming {
                        emptyState
                    }
                    ForEach(chat.thread?.messages ?? []) { m in
                        VStack(alignment: .leading, spacing: 8) {
                            let live = chat.activities.filter { $0.messageID == m.id }
                            if !live.isEmpty {
                                ActivityList(items: live, undo: chat.undo)
                            } else if let actions = m.actions, !actions.isEmpty {
                                ActivityList(items: actions.map { ChatActivity(activity: AgentActivity(symbol: "checkmark.circle", title: $0)) }, undo: nil)
                            }
                            MessageView(message: m, onCopy: { copy(m.text) }, onSaveNote: m.role == .assistant ? { saveNote(m.text) } : nil)
                        }
                        .id(m.id)
                    }
                    if chat.isStreaming {
                        VStack(alignment: .leading, spacing: 8) {
                            let pending = chat.activities.filter { $0.messageID == nil }
                            if !pending.isEmpty { ActivityList(items: pending, undo: chat.undo) }
                            if let progress = chat.toolProgress {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text(progress + "…").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                                }
                                .transition(.opacity)
                            }
                            if !chat.streamingText.isEmpty || chat.toolProgress == nil {
                                MessageView(message: ChatMessage(role: .assistant, text: chat.streamingText), streaming: true)
                            }
                        }
                        .id("streaming")
                    }
                    if let error = chat.error {
                        ErrorCard(message: error)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
            }
            .scrollEdgeEffectStyle(.soft, for: .all)
            .onChange(of: chat.streamingText) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: chat.activities.count) { _, _ in withAnimation(.snappy) { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: chat.thread?.messages.count) { _, _ in
                withAnimation(.snappy) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var emptyState: some View {
        let hasPassage = chat.thread?.passage != nil
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(hasPassage ? "What would you like to know?" : "Ask about \(reader.title)")
                    .font(.system(.title3, design: .serif).weight(.semibold))
                    .lineLimit(2)
                Text(hasPassage ? "Pick a starting point or type your own question."
                                : "Claude can see the \(chat.scope == .book ? "whole book" : "chapter you’re reading").")
                    .font(.callout).foregroundStyle(.secondary)
            }
            VStack(spacing: 6) {
                ForEach(ClaudeQuickAction.allCases.filter { hasPassage || $0 != .define }) { action in
                    Button { chat.send(action.prompt(hasPassage: hasPassage)) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: action.symbol)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Self.accent)
                                .frame(width: 28, height: 28)
                                .background(Self.accent.opacity(0.14), in: .rect(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(action.title).font(.system(size: 13, weight: .medium))
                                Text(action.subtitle(hasPassage: hasPassage)).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(HoverRowStyle())
                }
            }
        }
        .padding(.top, 2)
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(chat.thread?.messages.isEmpty == false ? "Ask a follow-up…" : "Ask anything about this book…",
                      text: $chat.input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .lineLimit(1...7)
                .focused($inputFocused)
                .onSubmit { chat.send() }
                .accessibilityLabel("Question for Claude")
            HStack(spacing: 6) {
                Menu {
                    Picker("Context", selection: $chat.scope) {
                        ForEach(ClaudeScope.allCases.filter { $0 != .passage || chat.thread?.passage != nil }, id: \.self) { s in
                            Label(s == .passage ? "Selection Only" : s.label, systemImage: s.symbol).tag(s)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Chip(symbol: chat.scope.symbol, title: chat.scope == .passage ? "Selection" : chat.scope.label)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("What Claude can read")

                Menu {
                    Picker("Model", selection: $chat.model) {
                        ForEach(ClaudeModel.allCases) { m in
                            Label { Text("\(m.name) — \(m.detail)") } icon: { Image(systemName: m.symbol) }.tag(m)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Chip(symbol: chat.model.symbol, title: chat.model.name)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Claude model")

                Spacer()

                if chat.isStreaming {
                    Button { chat.cancel() } label: {
                        Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold))
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(.primary.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .help("Stop")
                    .accessibilityLabel("Stop")
                } else {
                    let empty = chat.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    Button { chat.send() } label: {
                        Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(empty ? AnyShapeStyle(.gray.opacity(0.4)) : AnyShapeStyle(Self.accent.gradient)))
                    }
                    .buttonStyle(.plain)
                    .disabled(empty)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Send (↩)")
                    .accessibilityLabel("Send")
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18).fill(.background.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(inputFocused ? Self.accent.opacity(0.55) : .primary.opacity(0.1), lineWidth: 1))
        .animation(.easeOut(duration: 0.15), value: inputFocused)
        .padding(12)
    }

    // MARK: History

    private var history: some View {
        let threads = reader.state.liveChats
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { reader.claudeShowsHistory = false } label: {
                    Label("Back", systemImage: "chevron.left").font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Self.accent)
                Spacer()
                Text("Conversations").font(.system(size: 14, weight: .semibold))
                Spacer()
                PanelIconButton(symbol: "square.and.pencil", label: "New Conversation") {
                    chat.newThread()
                    reader.claudeShowsHistory = false
                    inputFocused = true
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            Divider().opacity(0.35)

            if threads.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
                    Text("No conversations yet").font(.headline)
                    Text("Questions you ask about this book will be kept here, on every Mac.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(30)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(threads) { t in
                            HistoryRow(thread: t, isCurrent: t.id == chat.thread?.id,
                                       open: { chat.open(t); reader.claudeShowsHistory = false },
                                       delete: { withAnimation(.snappy) { chat.delete(t) } })
                        }
                    }
                    .padding(10)
                }
                .scrollEdgeEffectStyle(.soft, for: .all)
                Text("\(threads.count) conversation\(threads.count == 1 ? "" : "s") · synced with iCloud")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .padding(.bottom, 12)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func saveNote(_ text: String) {
        let passage = chat.thread?.passage
        let locator = chat.thread?.locator ?? reader.location
        reader.library.update(reader.book.id) { s in
            if let passage, let i = s.highlights.lastIndex(where: { !$0.deleted && $0.text == passage }) {
                s.highlights[i].note = [s.highlights[i].note, text].compactMap { $0 }.joined(separator: "\n\n")
                s.highlights[i].updated = Date()
            } else {
                s.bookmarks.append(Bookmark(locator: locator, snippet: "Claude: " + String(text.prefix(300))))
            }
        }
        reader.engine?.refreshHighlights()
    }
}

struct ClaudeAvatar: View {
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(LinearGradient(colors: [Color(hex: "#E08A68"), Color(hex: "#B8532F")],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing)))
            .accessibilityHidden(true)
    }
}

private struct PanelIconButton: View {
    let symbol: String
    let label: String
    var badge: Int = 0
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .background(Circle().fill(.primary.opacity(hovering ? 0.1 : 0)))
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text("\(badge)")
                            .font(.system(size: 8.5, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 3.5).frame(minWidth: 13, minHeight: 13)
                            .background(Capsule().fill(Color(hex: "#C96442")))
                            .offset(x: 3, y: -2)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct Chip: View {
    let symbol: String
    let title: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold))
            Text(title).font(.system(size: 11.5, weight: .medium))
            Image(systemName: "chevron.down").font(.system(size: 7.5, weight: .bold)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(Capsule().fill(.primary.opacity(0.08)))
        .contentShape(Capsule())
    }
}

private struct HoverRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverRow(configuration: configuration)
    }

    private struct HoverRow: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: 12).fill(.primary.opacity(configuration.isPressed ? 0.12 : hovering ? 0.07 : 0.035)))
                .onHover { hovering = $0 }
        }
    }
}

private struct HistoryRow: View {
    let thread: ChatThread
    let isCurrent: Bool
    let open: () -> Void
    let delete: () -> Void
    @State private var hovering = false
    @State private var confirming = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: thread.passage != nil ? "text.quote" : "bubble.left.and.text.bubble.right")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(hex: "#C96442"))
                .frame(width: 28, height: 28)
                .background(Color(hex: "#C96442").opacity(0.14), in: .rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(thread.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                if let last = thread.messages.last(where: { $0.role == .assistant }) {
                    Text(Markdown.attributed(last.text.replacingOccurrences(of: "\n", with: " ")))
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 4) {
                    Text(thread.updated, format: .relative(presentation: .named))
                    Text("·")
                    Text("\(thread.messages.count) message\(thread.messages.count == 1 ? "" : "s")")
                    if isCurrent { Text("· Open").foregroundStyle(Color(hex: "#C96442")) }
                }
                .font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            if confirming {
                VStack(spacing: 4) {
                    Button("Delete", role: .destructive, action: delete)
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .controlSize(.small)
                    Button("Cancel") { withAnimation(.snappy) { confirming = false } }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else {
                Button { withAnimation(.snappy) { confirming = true } } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(hovering ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete Conversation")
                .accessibilityLabel("Delete conversation")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14).fill(.primary.opacity(hovering ? 0.07 : isCurrent ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0; if !$0 { confirming = false } }
        .contextMenu {
            Button("Open", systemImage: "arrow.right.circle", action: open)
            Button("Delete Conversation", systemImage: "trash", role: .destructive, action: delete)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Open", open)
    }
}

private struct PassageCard: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(Color(hex: "#C96442").gradient).frame(width: 3)
            Text(text)
                .font(.system(.callout, design: .serif).italic())
                .lineLimit(expanded ? nil : 4)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 14))
        .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
    }
}

private struct ErrorCard: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Claude couldn’t answer", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
            Text(Markdown.attributed(message)).font(.callout).textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1), in: .rect(cornerRadius: 14))
    }
}

private struct MessageView: View {
    let message: ChatMessage
    var streaming = false
    var onCopy: (() -> Void)?
    var onSaveNote: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .glassEffect(.regular.tint(Color(hex: "#C96442").opacity(0.35)), in: .rect(cornerRadius: 18))
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                MarkdownText(text: message.text + (streaming ? " ▍" : ""))
                if !streaming {
                    HStack(spacing: 2) {
                        if let onCopy {
                            Button(action: onCopy) { Label("Copy", systemImage: "doc.on.doc") }
                        }
                        if let onSaveNote {
                            Button(action: onSaveNote) { Label("Save to Notes", systemImage: "note.text.badge.plus") }
                        }
                    }
                    .buttonStyle(MessageActionStyle())
                    .opacity(hovering ? 1 : 0.0)
                }
            }
            .onHover { hovering = $0 }
        }
    }
}

/// Renders Claude's Markdown: paragraphs, headings, lists, quotes and code.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Markdown.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let t):
                    Text(Markdown.attributed(t)).font(level <= 2 ? .headline : .subheadline.weight(.semibold))
                case .paragraph(let t):
                    Text(Markdown.attributed(t)).font(.system(size: 14)).lineSpacing(3)
                case .code(let c):
                    Text(c).font(.system(.callout, design: .monospaced))
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
                case .quote(let lines):
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 1.5).fill(.secondary.opacity(0.5)).frame(width: 3)
                        Text(Markdown.attributed(lines.joined(separator: " ")))
                            .font(.system(size: 14, design: .serif).italic()).foregroundStyle(.secondary)
                    }
                case .list(let ordered, let items):
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(ordered ? "\(i + 1)." : "•").foregroundStyle(.secondary).monospacedDigit()
                                Text(Markdown.attributed(item)).font(.system(size: 14))
                            }
                        }
                    }
                case .rule:
                    Divider()
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Wraps children onto multiple lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 360
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private struct MessageActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(.primary.opacity(configuration.isPressed ? 0.14 : 0.06)))
    }
}

/// Cards for what Claude did in the app, each with Undo while the session lasts.
private struct ActivityList: View {
    let items: [ChatActivity]
    let undo: ((UUID) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(items) { item in
                HStack(spacing: 8) {
                    Image(systemName: item.undone ? "arrow.uturn.backward" : item.activity.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(hex: "#C96442"))
                        .frame(width: 22, height: 22)
                        .background(Color(hex: "#C96442").opacity(0.14), in: .rect(cornerRadius: 6))
                    Text(item.activity.title)
                        .font(.system(size: 12))
                        .strikethrough(item.undone)
                        .foregroundStyle(item.undone ? .secondary : .primary)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    if item.undone {
                        Text("Undone").font(.system(size: 11)).foregroundStyle(.secondary)
                    } else if let undo, item.activity.undo != nil {
                        Button(item.activity.undoLabel) { undo(item.id) }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Color(hex: "#C96442"))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 10).fill(.primary.opacity(0.05)))
            }
        }
    }
}
