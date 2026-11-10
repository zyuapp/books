import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class ClaudeChat {
    var thread: ChatThread?
    var input = ""
    /// Passage the next question is about, shown above the composer until sent.
    var pendingPassage: String?
    /// The part of the streaming answer on screen so far.
    var streamingText = ""
    var isStreaming = false
    var error: String?
    /// What a running tool is doing, e.g. "Reading your highlights".
    var toolProgress: String?
    /// Changes Claude made this session, kept so they can be undone. `messageID` is nil while the answer streams.
    var activities: [ChatActivity] = []
    /// Undos since the last question, so Claude knows its change was reverted on purpose.
    @ObservationIgnored private var undoneSinceLastSend: [String] = []
    var model: ClaudeModel {
        didSet { UserDefaults.standard.set(model.rawValue, forKey: "claudeModel") }
    }
    var effort: ClaudeEffort {
        didSet { UserDefaults.standard.set(effort.rawValue, forKey: "claudeEffort") }
    }

    /// Scroll offset per conversation while the book is open; absent means pinned to the bottom.
    @ObservationIgnored var scrollOffsets: [UUID: CGFloat] = [:]
    /// Set by New Conversation, so a passage asked about next starts there instead of joining a recent conversation.
    @ObservationIgnored private var wantsNewThread = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var revealTask: Task<Void, Never>?
    @ObservationIgnored private var received: [Character] = []
    @ObservationIgnored private var shown = 0
    @ObservationIgnored private var receivedAll = false
    @ObservationIgnored private weak var reader: ReaderModel?

    init(reader: ReaderModel) {
        self.reader = reader
        model = ClaudeModel(rawValue: UserDefaults.standard.string(forKey: "claudeModel") ?? "") ?? .sonnet
        effort = ClaudeEffort(rawValue: UserDefaults.standard.string(forKey: "claudeEffort") ?? "") ?? .low
    }

    /// The conversation to continue: the open one, else the latest, as long as it was active within the last hour.
    private var recentThread: ChatThread? {
        let cutoff = Date().addingTimeInterval(-3600)
        if let thread, !thread.messages.isEmpty { return isStreaming || thread.updated > cutoff ? thread : nil }
        if wantsNewThread { return nil }
        return reader?.state.liveChats.first { !$0.messages.isEmpty && $0.updated > cutoff }
    }

    func begin(with seed: ClaudeRequestSeed) {
        if let recent = recentThread {
            if recent.id != thread?.id { open(recent) }
        } else if thread?.messages.isEmpty == false {
            newThread()
        }
        error = nil
        pendingPassage = seed.passage
        if let action = seed.action {
            if isStreaming { cancel() }
            send(action.prompt(hasPassage: seed.passage != nil))
        }
    }

    /// Forgets a passage the reader opened the panel with but never asked about.
    func dropUnusedPassage() {
        guard input.isEmpty else { return }
        pendingPassage = nil
    }

    func newThread() {
        cancel()
        thread = nil
        error = nil
        input = ""
        pendingPassage = nil
        wantsNewThread = true
    }

    func open(_ t: ChatThread) {
        cancel()
        thread = t
        error = nil
        wantsNewThread = false
    }

    func cancel() {
        task?.cancel()
        task = nil
        revealTask?.cancel()
        revealTask = nil
        if isStreaming, !streamingText.isEmpty { appendAssistant(streamingText + " …") }
        isStreaming = false
        streamingText = ""
    }

    /// Shows received text a few words per frame, faster the further it lags, so bursts from the stream read smoothly.
    private func startReveal() {
        received = []
        shown = 0
        receivedAll = false
        streamingText = ""
        revealTask = Task { [weak self] in
            while !Task.isCancelled, self?.revealNext() == true {
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    /// Returns false once the answer is complete and fully shown.
    private func revealNext() -> Bool {
        let backlog = received.count - shown
        guard backlog > 0 else { return !receivedAll }
        var end = min(received.count, shown + max(2, backlog / 15))
        while end < received.count, !received[end - 1].isWhitespace { end += 1 }
        if !receivedAll, !received[end - 1].isWhitespace {
            // The last word may still be arriving.
            guard let space = received[shown..<end].lastIndex(where: \.isWhitespace) else { return true }
            end = space + 1
        }
        streamingText.append(contentsOf: received[shown..<end])
        shown = end
        return true
    }

    func send(_ text: String? = nil) {
        let question = (text ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isStreaming, let reader else { return }
        input = ""
        error = nil
        let selected = pendingPassage
        pendingPassage = nil
        if thread == nil {
            thread = ChatThread(title: ChatThread.title(from: selected ?? question), passage: nil, locator: reader.location)
            wantsNewThread = false
        }
        let history = thread!.messages
        let legacyPassage = thread!.passage
        thread!.messages.append(ChatMessage(role: .user, text: question, passage: selected))
        thread!.updated = Date()
        persist()

        isStreaming = true
        startReveal()
        let passage = selected ?? legacyPassage
        let undone = undoneSinceLastSend
        undoneSinceLastSend = []
        let model = model
        let effort = effort
        task = Task {
            let page = await reader.engine?.currentPageText() ?? ""
            let system = Self.systemPrompt(reader: reader)
            var prompt = Self.prompt(page: page, passage: passage, history: history, question: question)
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
                for try await event in ClaudeService.stream(prompt: prompt, system: system, model: model, effort: effort, toolsConfig: access?.config) {
                    if Task.isCancelled { break }
                    switch event {
                    case .text(let t):
                        if let label = toolProgress, Self.webToolLabels.values.contains(label) { toolProgress = nil }
                        received.append(contentsOf: t)
                    case .tool(let name):
                        if let label = Self.webToolLabels[name] {
                            withAnimation(.easeOut(duration: 0.2)) { toolProgress = label }
                        }
                    case .finished:
                        break
                    }
                }
                guard !Task.isCancelled else { return }
                receivedAll = true
                await revealTask?.value
                guard !Task.isCancelled else { return }
                appendAssistant(String(received))
            } catch {
                guard !Task.isCancelled else { return }
                if !received.isEmpty { appendAssistant(String(received)) }
                self.error = error.localizedDescription
            }
            revealTask?.cancel()
            revealTask = nil
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

    /// Deletes every conversation about the open book.
    func deleteAll() {
        guard let reader else { return }
        cancel()
        reader.library.update(reader.book.id) { s in
            for i in s.chats.indices where !s.chats[i].deleted {
                s.chats[i].deleted = true
                s.chats[i].updated = Date()
            }
        }
        thread = nil
        error = nil
    }

    private static let webToolLabels = ["WebSearch": "Searching the web", "WebFetch": "Reading a web page"]

    private static func systemPrompt(reader: ReaderModel) -> String {
        let author = reader.publication?.author ?? reader.state.author
        let pct = Int((reader.location.totalProgress * 100).rounded())
        let where_ = [reader.chapterTitle, "\(pct)% through the book"].compactMap { $0 }.joined(separator: ", ")
        return """
        You are a warm, perceptive reading companion built into a book reader app. The reader is reading \
        “\(reader.title)”\(author.map { " by \($0)" } ?? ""). They are currently at: \(where_).
        You're given the text of the page they're on. When a question needs more of the book, such as the chapter, \
        earlier events or a theme across the book, use read_text, search_text and get_table_of_contents to look it up. \
        Answer from the book text when it's relevant, and from your own knowledge otherwise. \
        You can search the web with WebSearch and read pages with WebFetch. Use them when the reader asks you to check \
        or look something up, or when the answer depends on facts outside the book that you're unsure of or that may \
        have changed. Cite what you found as Markdown links to the sources. \
        Be concise and specific: short paragraphs, quotes from the text when helpful, light Markdown (bold, italics, short lists). \
        The chat draws ```mermaid code blocks as diagrams: when a diagram, flowchart, timeline or map of ideas would help, or the \
        reader asks for one, include it as a mermaid block rather than describing it. The panel is narrow, so lay diagrams out \
        left to right (`flowchart LR`), keep labels short and use at most about 10 nodes. \
        Never reveal plot developments beyond the reader's current position unless they explicitly ask for spoilers.
        \(AgentToolbox.guidance)
        """
    }

    private static func prompt(page: String, passage: String?, history: [ChatMessage], question: String) -> String {
        var parts: [String] = []
        if !page.isEmpty {
            let limit = 150_000
            let clipped = page.count > limit ? String(page.prefix(limit)) + "\n[…truncated…]" : page
            parts.append("<current_page>\n\(clipped)\n</current_page>")
        }
        if let passage { parts.append("<selected_passage>\n\(passage)\n</selected_passage>") }
        if !history.isEmpty {
            let convo = history.map { m in
                let quote = m.passage.map { "(about the passage “\($0)”) " } ?? ""
                return "\(m.role == .user ? "Reader" : "You"): \(quote)\(m.text)"
            }.joined(separator: "\n\n")
            parts.append("<conversation_so_far>\n\(convo)\n</conversation_so_far>")
        }
        parts.append(question)
        return parts.joined(separator: "\n\n")
    }
}

/// Typeface for Claude's replies, chosen in Settings › Claude.
enum ChatFont: String, CaseIterable, Identifiable {
    case charter, newYork, system

    static let key = "chatFont"
    var id: String { rawValue }
    var name: String {
        switch self {
        case .charter: "Charter"
        case .newYork: "New York"
        case .system: "San Francisco"
        }
    }
    func font(_ size: CGFloat) -> Font {
        switch self {
        case .charter: .custom("Charter", size: size)
        case .newYork: .system(size: size, design: .serif)
        case .system: .system(size: size)
        }
    }
}

/// Reply text size in points, chosen in Settings › Claude; the rest of the conversation scales with it.
enum ChatTextSize {
    static let key = "chatTextSize"
    static let standard = 15.5
    static let options: [(name: String, size: Double)] = [
        ("Small", 13.5), ("Default", 15.5), ("Large", 17.5), ("Extra Large", 19.5), ("Huge", 22),
    ]
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
    @State private var confirmingClearAll = false
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    /// Off until the saved offset is applied, so the first layout's offset isn't saved over it.
    @State private var tracksScroll = false
    /// Whether new text keeps the conversation scrolled to the bottom; off while the reader scrolls back.
    @State private var followsLatest = true
    @AppStorage(ChatTextSize.key) private var textSize = ChatTextSize.standard

    private static let accent = Color.brand
    private static let readableWidth: CGFloat = 680
    static let compactWidth: CGFloat = 400

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
        .animation(Motion.panel, value: reader.claudeShowsHistory)
        .frame(maxWidth: reader.claudeExpanded ? .infinity : Self.compactWidth)
        .clipShape(.rect(cornerRadius: 26))
        .readerPanelSurface(theme)
        .readerOverlay()
        .onChange(of: reader.claudeDraft) { _, seed in
            if let seed { chat.begin(with: seed); reader.claudeShowsHistory = false; reader.claudeDraft = nil }
        }
        .onChange(of: reader.claudeNewThreadRequested) { _, requested in
            if requested { startNewThread() }
        }
        .onChange(of: reader.claudeFocusRequest) { _, _ in
            reader.claudeShowsHistory = false
            focusInput()
        }
        .onChange(of: inputFocused) { _, f in reader.claudeInputFocused = f }
        .onAppear {
            if let seed = reader.claudeDraft {
                chat.begin(with: seed)
                reader.claudeDraft = nil
            } else {
                chat.dropUnusedPassage()
            }
            if reader.claudeNewThreadRequested { startNewThread() }
            focusInput()
        }
        .onDisappear { reader.claudeInputFocused = false }
    }

    private func startNewThread() {
        reader.claudeNewThreadRequested = false
        chat.newThread()
        reader.claudeShowsHistory = false
    }

    /// Focus set during the same update as the field's insertion is dropped, so it waits a run-loop turn.
    private func focusInput() {
        DispatchQueue.main.async { inputFocused = true }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            ClaudeAvatar(size: 30)
            Text(chat.thread?.messages.isEmpty == false ? (chat.thread?.title ?? "Claude") : "Claude")
                .font(.headline).lineLimit(1)
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                PanelIconButton(symbol: "clock.arrow.circlepath", label: "Conversations") { reader.claudeShowsHistory = true }
                PanelIconButton(symbol: "square.and.pencil", label: "New Conversation") {
                    chat.newThread()
                    inputFocused = true
                }
                PanelIconButton(symbol: reader.claudeExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                label: reader.claudeExpanded ? "Make Smaller" : "Expand") {
                    withAnimation(Motion.panel) { reader.claudeExpanded.toggle() }
                }
                PanelIconButton(symbol: "xmark", label: "Close") {
                    withAnimation(Motion.panel) { reader.showClaude = false }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: Self.readableWidth)
        .frame(maxWidth: .infinity)
    }

    // MARK: Conversation

    private var conversation: some View {
        GeometryReader { viewport in ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let passage = chat.thread?.passage {
                        PassageCard(text: passage)
                    }
                    if chat.thread?.messages.isEmpty ?? true, !chat.isStreaming {
                        emptyState
                    }
                    ForEach(chat.thread?.messages ?? []) { m in
                        VStack(alignment: .leading, spacing: 12) {
                            let live = chat.activities.filter { $0.messageID == m.id }
                            if !live.isEmpty {
                                ActivityList(items: live, undo: chat.undo)
                            } else if let actions = m.actions, !actions.isEmpty {
                                ActivityList(items: actions.map { ChatActivity(activity: AgentActivity(symbol: "checkmark.circle", title: $0)) }, undo: nil)
                            }
                            if let passage = m.passage { PassageCard(text: passage) }
                            MessageView(message: m)
                        }
                        .id(m.id)
                    }
                    if chat.isStreaming {
                        VStack(alignment: .leading, spacing: 8) {
                            let pending = chat.activities.filter { $0.messageID == nil }
                            if !pending.isEmpty { ActivityList(items: pending, undo: chat.undo) }
                            if let progress = chat.toolProgress ?? (chat.streamingText.isEmpty ? "Thinking" : nil) {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text(progress + "…").font(.callout.weight(.medium)).foregroundStyle(.secondary)
                                }
                                .transition(.opacity)
                            }
                            if !chat.streamingText.isEmpty {
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
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 52)
                .frame(maxWidth: Self.readableWidth)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: .top)
            }
            .softScrollEdges(.all)
            .verticalEdgeFade()
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: CGFloat?.self) { g in
                g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 8 ? nil : g.contentOffset.y
            } action: { _, offset in
                guard tracksScroll, let id = chat.thread?.id else { return }
                chat.scrollOffsets[id] = offset
            }
            .onScrollPhaseChange { _, phase, context in
                if phase == .interacting {
                    followsLatest = false
                } else if phase == .idle {
                    let g = context.geometry
                    followsLatest = g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 40
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { old, new in
                guard chat.isStreaming, followsLatest, new > old else { return }
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onAppear(perform: restoreScroll)
            .onChange(of: chat.thread?.id) { _, _ in restoreScroll() }
            .onChange(of: chat.activities.count) { _, _ in
                guard followsLatest else { return }
                withAnimation(.snappy) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: chat.thread?.messages.count) { _, _ in
                if chat.thread?.messages.last?.role == .user { followsLatest = true }
                guard followsLatest else { return }
                withAnimation(.snappy) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        } }
    }

    private func restoreScroll() {
        tracksScroll = false
        followsLatest = chat.thread.map { chat.scrollOffsets[$0.id] == nil } ?? true
        DispatchQueue.main.async {
            if let id = chat.thread?.id, let y = chat.scrollOffsets[id] {
                scrollPosition.scrollTo(y: y)
            } else {
                scrollPosition.scrollTo(edge: .bottom)
            }
            DispatchQueue.main.async { tracksScroll = true }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Text(chat.pendingPassage != nil || chat.thread?.passage != nil ? "Chat with Claude about this passage" : "Chat with Claude about anything in this book")
                    .font(.system(size: 26, weight: .semibold))
                Text("It uses your Claude subscription. Claude can also find your place, highlight passages, bookmark pages, organize your library and change your reading settings.")
                    .font(.title3).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            capabilitiesRow
        }
        .padding(.top, 2)
    }

    private var capabilitiesRow: some View {
        Button { chat.send("What can you do for me?") } label: {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Self.accent)
                    .frame(width: 28, height: 28)
                    .background(Self.accent.opacity(0.14), in: .rect(cornerRadius: 8))
                Text("What can you do for me?").font(.body.weight(.medium))
                Spacer()
                Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle())
    }

    // MARK: Composer

    /// A checkable menu row; the second text shows as the system's subtitle line.
    private func menuOption(_ name: String, detail: String, selected: Bool, select: @escaping () -> Void) -> some View {
        Toggle(isOn: Binding(get: { selected }, set: { if $0 { select() } })) {
            Text(name)
            Text(detail)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let passage = chat.pendingPassage {
                PendingPassage(text: passage) { withAnimation(.snappy) { chat.pendingPassage = nil } }
                    .transition(.opacity)
            }
            TextField(chat.pendingPassage != nil ? "Ask about this passage…"
                      : chat.thread?.messages.isEmpty == false ? "Ask a follow-up…" : "Ask anything about this book…",
                      text: $chat.input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5 * textSize / ChatTextSize.standard))
                .lineLimit(1...7)
                .focused($inputFocused)
                .onSubmit { chat.send() }
                .accessibilityLabel("Question for Claude")
            HStack(spacing: 6) {
                Menu {
                    Section("Model") {
                        ForEach(ClaudeModel.allCases) { m in
                            menuOption(m.name, detail: m.detail, selected: chat.model == m) { chat.model = m }
                        }
                    }
                } label: {
                    Chip(symbol: chat.model.symbol, title: chat.model.name)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .tooltip("Claude model")

                Menu {
                    Section("Effort") {
                        ForEach(ClaudeEffort.allCases) { e in
                            menuOption(e.name, detail: e.detail, selected: chat.effort == e) { chat.effort = e }
                        }
                    }
                } label: {
                    Chip(symbol: nil, title: "\(chat.effort.name) effort")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .tooltip("How hard Claude thinks")

                Spacer()

                if chat.isStreaming {
                    Button { chat.cancel() } label: {
                        Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold))
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(.primary.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .tooltip("Stop")
                    .accessibilityLabel("Stop")
                } else {
                    let empty = chat.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    Button { chat.send() } label: {
                        Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(empty ? AnyShapeStyle(Self.accent.opacity(0.4)) : AnyShapeStyle(Self.accent.gradient)))
                    }
                    .buttonStyle(.plain)
                    .disabled(empty)
                    .keyboardShortcut(.return, modifiers: .command)
                    .tooltip("Send (↩)")
                    .accessibilityLabel("Send")
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18).fill(.background.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(inputFocused ? Self.accent.opacity(0.55) : .primary.opacity(0.1), lineWidth: 1))
        .animation(.easeOut(duration: 0.15), value: inputFocused)
        .padding(12)
        .frame(maxWidth: Self.readableWidth)
    }

    // MARK: History

    private var history: some View {
        let threads = reader.state.liveChats
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                PanelIconButton(symbol: "chevron.left", label: "Back") { reader.claudeShowsHistory = false }
                Text("Conversations").font(.headline)
                Spacer()
                HStack(spacing: 4) {
                    PanelIconButton(symbol: "trash", label: "Delete All Conversations") { confirmingClearAll = true }
                        .disabled(threads.isEmpty)
                    PanelIconButton(symbol: "square.and.pencil", label: "New Conversation") {
                        chat.newThread()
                        reader.claudeShowsHistory = false
                        inputFocused = true
                    }
                }
            }
            .confirmationDialog("Delete all conversations about this book?", isPresented: $confirmingClearAll) {
                Button("Delete All", role: .destructive) { withAnimation(.snappy) { chat.deleteAll() } }
            } message: {
                Text("\(threads.count == 1 ? "1 conversation" : "\(threads.count) conversations") will be removed from all your devices.")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: Self.readableWidth)
            .frame(maxWidth: .infinity)
            Divider().opacity(0.35)

            if threads.isEmpty {
                EmptyStateView(symbol: "bubble.left.and.text.bubble.right", title: "No conversations yet",
                               detail: "Questions you ask about this book will be kept here, on every Mac.")
                    .frame(maxHeight: .infinity)
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
                    .frame(maxWidth: Self.readableWidth)
                    .frame(maxWidth: .infinity)
                }
                .softScrollEdges(.all)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
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
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .background(Circle().fill(.primary.opacity(hovering ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .tooltip(label)
        .accessibilityLabel(label)
    }
}

private struct Chip: View {
    let symbol: String?
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).font(.system(size: 12, weight: .semibold)) }
            Text(title).font(.body.weight(.medium))
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Capsule().fill(.primary.opacity(0.1)))
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
            VStack(alignment: .leading, spacing: 3) {
                Text(thread.title).font(.body.weight(.medium)).lineLimit(2)
                if let last = thread.messages.last(where: { $0.role == .assistant }) {
                    Text(ChatThread.preview(of: last.text))
                        .font(.callout).foregroundStyle(.primary.opacity(0.65)).lineLimit(2)
                }
                HStack(spacing: 4) {
                    Text(thread.updated, format: .relative(presentation: .named))
                    if isCurrent { Text("· Open").foregroundStyle(Color.brand) }
                }
                .font(.callout).foregroundStyle(.primary.opacity(0.65))
            }
            Spacer(minLength: 4)
            Button { confirming = true } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(hovering ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .tooltip("Delete Conversation")
            .accessibilityLabel("Delete conversation")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.primary.opacity(hovering ? 0.07 : isCurrent ? 0.05 : 0)))
        .overlay(alignment: .bottom) { Divider().opacity(0.6) }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open", systemImage: "arrow.right.circle", action: open)
            Button("Delete Conversation…", systemImage: "trash", role: .destructive) { confirming = true }
        }
        .confirmationDialog("Delete this conversation?", isPresented: $confirming) {
            Button("Delete", role: .destructive, action: delete)
        } message: {
            Text("“\(thread.title)” will be removed from all your devices.")
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
            RoundedRectangle(cornerRadius: 2).fill(Color.brand.gradient).frame(width: 3)
            Text(text)
                .font(.custom("Charter", size: 14))
                .lineLimit(expanded ? nil : 3)
                .foregroundStyle(.primary.opacity(0.8))
                .textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.05), in: .rect(cornerRadius: 14))
        .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
    }
}

/// The passage attached to the next question, with a button to remove it.
private struct PendingPassage: View {
    let text: String
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5).fill(Color.brand.gradient).frame(width: 3)
            Text(text.collapsingWhitespace)
                .font(.custom("Charter", size: 13))
                .lineLimit(2)
                .foregroundStyle(.primary.opacity(0.75))
            Spacer(minLength: 4)
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .tooltip("Remove Passage")
            .accessibilityLabel("Remove passage")
        }
        .padding(8)
        .background(.primary.opacity(0.05), in: .rect(cornerRadius: 10))
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
    @AppStorage(ChatTextSize.key) private var textSize = ChatTextSize.standard

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .font(.system(size: 14.6 * textSize / ChatTextSize.standard))
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color.brand.opacity(0.14), in: .rect(cornerRadius: 18))
            }
        } else {
            MarkdownText(text: message.text, rendersDiagrams: !streaming)
        }
    }
}

/// Renders Claude's Markdown: paragraphs, headings, lists, tables, quotes and code.
struct MarkdownText: View {
    let text: String
    var rendersDiagrams = true

    @AppStorage(ChatFont.key) private var face = ChatFont.charter
    @AppStorage(ChatTextSize.key) private var size = ChatTextSize.standard

    private var scale: CGFloat { size / ChatTextSize.standard }
    private func serif(_ points: CGFloat) -> Font { face.font(points * scale) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Markdown.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let t):
                    Text(Markdown.attributed(t)).font(serif(level <= 2 ? 17 : 15.5).bold())
                case .paragraph(let t):
                    Text(Markdown.attributed(t)).font(serif(15.5)).lineSpacing(3.5 * scale)
                case .code(let c, "mermaid") where rendersDiagrams:
                    MermaidDiagram(source: c)
                case .code(let c, _):
                    Text(c).font(.system(size: 12.5 * scale, design: .monospaced))
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
                case .quote(let lines):
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 1.5).fill(.secondary.opacity(0.5)).frame(width: 3)
                        Text(Markdown.attributed(lines.joined(separator: " ")))
                            .font(serif(15.5).italic()).foregroundStyle(.primary.opacity(0.78))
                    }
                case .list(let ordered, let items):
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(ordered ? "\(i + 1)." : "•").font(serif(15.5)).foregroundStyle(.secondary).monospacedDigit()
                                Text(Markdown.attributed(item)).font(serif(15.5)).lineSpacing(3 * scale)
                            }
                        }
                    }
                case .table(let header, let rows):
                    Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 7) {
                        GridRow {
                            ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                                Text(Markdown.attributed(cell)).font(serif(14.5).bold())
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            Divider().gridCellUnsizedAxes(.horizontal)
                            GridRow {
                                ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                    Text(Markdown.attributed(cell)).font(serif(14.5)).lineSpacing(2.5 * scale)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
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

/// Cards for what Claude did in the app, each with Undo while the session lasts.
private struct ActivityList: View {
    let items: [ChatActivity]
    let undo: ((UUID) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(items) { item in
                HStack(spacing: 8) {
                    Image(systemName: item.undone ? "arrow.uturn.backward" : item.activity.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                    Text(item.activity.title)
                        .font(.callout)
                        .strikethrough(item.undone)
                        .foregroundStyle(.primary.opacity(0.65))
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    if item.undone {
                        Text("Undone").font(.callout).foregroundStyle(.secondary)
                    } else if let undo, item.activity.undo != nil {
                        Button(item.activity.undoLabel) { undo(item.id) }
                            .buttonStyle(.borderless)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Color.brand)
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }
}
