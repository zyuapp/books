import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class AssistantChat {
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
    /// Changes ChatGPT made this session, kept so they can be undone. `messageID` is nil while the answer streams.
    var activities: [ChatActivity] = []
    /// Undos since the last question, so ChatGPT knows its change was reverted on purpose.
    @ObservationIgnored private var undoneSinceLastSend: [String] = []
    /// Slug of the ChatGPT model to ask.
    var model: String {
        didSet { UserDefaults.standard.set(model, forKey: ChatSettings.modelKey) }
    }
    var effort: String {
        didSet { UserDefaults.standard.set(effort, forKey: ChatSettings.effortKey) }
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
        model = UserDefaults.standard.string(forKey: ChatSettings.modelKey) ?? ChatGPTModel.fallback.slug
        effort = UserDefaults.standard.string(forKey: ChatSettings.effortKey) ?? "low"
    }

    /// The conversation to continue: the open one, else the latest, as long as it was active within the last hour.
    private var recentThread: ChatThread? {
        let cutoff = Date().addingTimeInterval(-3600)
        if let thread, !thread.messages.isEmpty { return isStreaming || thread.updated > cutoff ? thread : nil }
        if wantsNewThread { return nil }
        return reader?.state.liveChats.first { !$0.messages.isEmpty && $0.updated > cutoff }
    }

    func begin(with seed: AssistantRequestSeed) {
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
        guard !question.isEmpty, !isStreaming, !ChatGPTAccount.shared.usageLimitReached, let reader else { return }
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
            let input = Self.input(page: page, passage: passage, history: history, question: question, undone: undone)
            let session = AgentSession(reader: reader)
            session.onActivity = { [weak self] activity in
                withAnimation(.snappy) { self?.activities.append(ChatActivity(activity: activity)) }
            }
            session.onProgress = { [weak self] label in
                withAnimation(.easeOut(duration: 0.2)) { self?.toolProgress = label }
            }
            defer { toolProgress = nil }
            let selection = ChatSettings.resolve(model: model, effort: effort)
            do {
                for try await event in ChatGPTService.stream(input: input, instructions: system, model: selection.model,
                                                             effort: selection.effort, session: session) {
                    if Task.isCancelled { break }
                    switch event {
                    case .text(let t):
                        if toolProgress == Self.searchingLabel { toolProgress = nil }
                        received.append(contentsOf: t)
                    case .searching:
                        withAnimation(.easeOut(duration: 0.2)) { toolProgress = Self.searchingLabel }
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
                if case ChatGPTError.usageLimit = error {} else { self.error = error.localizedDescription }
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

    private static let searchingLabel = "Searching the web"

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
        You can search the web. Do so when the reader asks you to check or look something up, or when the answer \
        depends on facts outside the book that you're unsure of or that may have changed. Cite what you found as \
        Markdown links to the sources. \
        Be concise and specific: short paragraphs, quotes from the text when helpful, light Markdown (bold, italics, short lists). \
        The chat draws ```mermaid code blocks as diagrams: when a diagram, flowchart, timeline or map of ideas would help, or the \
        reader asks for one, include it as a mermaid block rather than describing it. The panel is narrow, so lay diagrams out \
        left to right (`flowchart LR`), keep labels short and use at most about 10 nodes. \
        Never reveal plot developments beyond the reader's current position unless they explicitly ask for spoilers.
        \(AgentToolbox.guidance)
        """
    }

    /// The conversation as Responses input: earlier turns as messages, then the page, passage and question.
    private static func input(page: String, passage: String?, history: [ChatMessage], question: String, undone: [String]) -> [[String: Any]] {
        var items: [[String: Any]] = history.map { m in
            let quote = m.passage.map { "(About the passage “\($0)”) " } ?? ""
            return ["type": "message", "role": m.role == .user ? "user" : "assistant", "content": quote + m.text]
        }
        var parts: [String] = []
        if !undone.isEmpty { parts.append("<app_events>\nThe reader pressed Undo on: " + undone.joined(separator: "; ") + "\n</app_events>") }
        if !page.isEmpty {
            let limit = 150_000
            let clipped = page.count > limit ? String(page.prefix(limit)) + "\n[…truncated…]" : page
            parts.append("<current_page>\n\(clipped)\n</current_page>")
        }
        if let passage { parts.append("<selected_passage>\n\(passage)\n</selected_passage>") }
        parts.append(question)
        items.append(["type": "message", "role": "user", "content": parts.joined(separator: "\n\n")])
        return items
    }
}

/// The model and effort the reader picked, shared by the composer and Settings.
@MainActor
enum ChatSettings {
    static let modelKey = "chatModel"
    static let effortKey = "chatEffort"

    static var models: [ChatGPTModel] {
        let list = ChatGPTAccount.shared.models
        return list.isEmpty ? [ChatGPTModel.fallback] : list
    }

    static func model(_ slug: String) -> ChatGPTModel {
        models.first { $0.slug == slug } ?? models[0]
    }

    /// Falls back to the first available model, and to its default effort when the chosen one isn't offered.
    static func resolve(model slug: String, effort: String) -> (model: String, effort: String) {
        let m = model(slug)
        if m.efforts.isEmpty || m.efforts.contains(effort) { return (m.slug, effort) }
        return (m.slug, m.defaultEffort ?? m.efforts[0])
    }
}

/// Typeface for ChatGPT's replies, chosen in Settings › ChatGPT.
enum ChatFont: String, CaseIterable, Identifiable {
    case system, seravek, charter, newYork

    static let standard = ChatFont.system

    static let key = "chatFont"
    var id: String { rawValue }
    var name: String {
        switch self {
        case .seravek: "Seravek"
        case .charter: "Charter"
        case .newYork: "New York"
        case .system: "San Francisco"
        }
    }
    func font(_ size: CGFloat) -> Font {
        switch self {
        case .seravek: .custom("Seravek", size: size)
        case .charter: .custom("Charter", size: size)
        case .newYork: .system(size: size, design: .serif)
        case .system: .system(size: size)
        }
    }
}

/// Reply text size in points, chosen in Settings › ChatGPT; the rest of the conversation scales with it.
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

struct AssistantPanel: View {
    let reader: ReaderModel
    @Bindable var chat: AssistantChat
    let theme: ReaderTheme
    @FocusState private var inputFocused: Bool
    @State private var confirmingClearAll = false
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    /// Off until the saved offset is applied, so the first layout's offset isn't saved over it.
    @State private var tracksScroll = false
    /// Whether new text keeps the conversation scrolled to the bottom; off while the reader scrolls back.
    @State private var followsLatest = true
    /// Set while the shown conversation was picked from the list, so the header offers a way back to it.
    @State private var openedFromHistory = false
    @AppStorage(ChatTextSize.key) private var textSize = ChatTextSize.standard

    private static let accent = Color.primary
    private static let readableWidth: CGFloat = 760
    static let compactWidth: CGFloat = 400

    var body: some View {
        ZStack {
            if reader.assistantShowsHistory {
                history
                    .transition(.move(edge: .leading).combined(with: .opacity))
            } else {
                VStack(spacing: 0) {
                    header
                    if !reader.assistantExpanded { Divider().opacity(0.35) }
                    conversation
                    if ChatGPTAccount.shared.status == .signedIn {
                        composer
                        planUsage
                    } else {
                        ChatGPTSignInCard(compact: !reader.assistantExpanded)
                            .padding(.horizontal, 12)
                            .padding(.bottom, reader.assistantExpanded ? 20 : 12)
                            .frame(maxWidth: Self.readableWidth)
                    }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(Motion.panel, value: reader.assistantShowsHistory)
        .frame(maxWidth: reader.assistantExpanded ? .infinity : Self.compactWidth)
        .modifier(PanelSurface(expanded: reader.assistantExpanded, theme: theme))
        .readerOverlay()
        .onChange(of: reader.assistantDraft) { _, seed in
            if let seed { chat.begin(with: seed); reader.assistantShowsHistory = false; openedFromHistory = false; reader.assistantDraft = nil }
        }
        .onChange(of: reader.assistantNewThreadRequested) { _, requested in
            if requested { startNewThread() }
        }
        .onChange(of: reader.assistantFocusRequest) { _, _ in
            reader.assistantShowsHistory = false
            focusInput()
        }
        .onChange(of: inputFocused) { _, f in reader.assistantInputFocused = f }
        .onAppear {
            if let seed = reader.assistantDraft {
                chat.begin(with: seed)
                reader.assistantDraft = nil
            } else {
                chat.dropUnusedPassage()
            }
            if reader.assistantNewThreadRequested { startNewThread() }
            focusInput()
        }
        .onDisappear { reader.assistantInputFocused = false }
    }

    private func startNewThread() {
        reader.assistantNewThreadRequested = false
        chat.newThread()
        reader.assistantShowsHistory = false
        openedFromHistory = false
    }

    /// Focus set during the same update as the field's insertion is dropped, so it waits a run-loop turn.
    private func focusInput() {
        DispatchQueue.main.async { inputFocused = true }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            if openedFromHistory {
                PanelIconButton(symbol: "chevron.left", label: "Back to Conversations") { reader.assistantShowsHistory = true }
            } else if !reader.assistantExpanded {
                AssistantAvatar(size: 30)
            }
            Text(chat.thread?.messages.isEmpty == false ? (chat.thread?.title ?? "ChatGPT") : reader.assistantExpanded ? "" : "ChatGPT")
                .font(reader.assistantExpanded ? .subheadline.weight(.medium) : .headline)
                .foregroundStyle(reader.assistantExpanded ? .secondary : .primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                PanelIconButton(symbol: "clock.arrow.circlepath", label: "Conversations") { reader.assistantShowsHistory = true }
                PanelIconButton(symbol: "square.and.pencil", label: "New Conversation") {
                    chat.newThread()
                    openedFromHistory = false
                    inputFocused = true
                }
                PanelIconButton(symbol: reader.assistantExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                label: reader.assistantExpanded ? "Make Smaller" : "Expand") {
                    withAnimation(Motion.panel) { reader.assistantExpanded.toggle() }
                }
                PanelIconButton(symbol: "xmark", label: "Close") {
                    withAnimation(Motion.panel) { reader.showAssistant = false }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, reader.assistantExpanded ? 6 : 12)
        .frame(maxWidth: reader.assistantExpanded ? .infinity : Self.readableWidth)
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
                    if ChatGPTAccount.shared.usageLimitReached {
                        UsageLimitCard()
                    } else if let error = chat.error {
                        ErrorCard(message: error)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, reader.assistantExpanded ? 24 : 16)
                .padding(.top, reader.assistantExpanded ? 28 : 16)
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
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(chat.pendingPassage != nil || chat.thread?.passage != nil ? "Ask about this passage" : "Ask about this book")
                    .font(.system(size: 22, weight: .semibold))
                Text("ChatGPT can also find your place, highlight, bookmark and change reading settings.")
                    .font(.body).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            if ChatGPTAccount.shared.status == .signedIn { capabilitiesRow }
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
                    .background(Self.accent.opacity(0.08), in: .rect(cornerRadius: 8))
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
                .font(.system(size: (reader.assistantExpanded ? 15.5 : 13.5) * textSize / ChatTextSize.standard))
                .lineLimit(reader.assistantExpanded ? 3...12 : 1...7)
                .padding(.horizontal, reader.assistantExpanded ? 4 : 0)
                .padding(.top, reader.assistantExpanded ? 4 : 0)
                .focused($inputFocused)
                .onSubmit { chat.send() }
                .accessibilityLabel("Question for ChatGPT")
            HStack(spacing: 6) {
                let current = ChatSettings.model(chat.model)
                Menu {
                    Section("Model") {
                        ForEach(ChatSettings.models) { m in
                            menuOption(m.name, detail: m.detail, selected: current.slug == m.slug) { chat.model = m.slug }
                        }
                    }
                } label: {
                    Chip(symbol: current.symbol, title: current.name)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .tooltip("ChatGPT model")

                if !current.efforts.isEmpty {
                    let effort = ChatSettings.resolve(model: chat.model, effort: chat.effort).effort
                    Menu {
                        Section("Reasoning") {
                            ForEach(current.efforts, id: \.self) { e in
                                menuOption(ChatGPTModel.effortName(e), detail: ChatGPTModel.effortDetail(e), selected: effort == e) { chat.effort = e }
                            }
                        }
                    } label: {
                        Chip(symbol: nil, title: "\(ChatGPTModel.effortName(effort)) effort")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .tooltip("How hard ChatGPT thinks")
                }

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
                        || ChatGPTAccount.shared.usageLimitReached
                    Button { chat.send() } label: {
                        Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.background)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Self.accent.opacity(empty ? 0.25 : 1)))
                    }
                    .buttonStyle(.plain)
                    .disabled(empty)
                    .keyboardShortcut(.return, modifiers: .command)
                    .tooltip("Send (↩)")
                    .accessibilityLabel("Send")
                }
            }
        }
        .padding(reader.assistantExpanded ? 16 : 12)
        .background(RoundedRectangle(cornerRadius: 18).fill(.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(inputFocused ? Self.accent.opacity(0.25) : .primary.opacity(0.08), lineWidth: 1))
        .animation(.easeOut(duration: 0.15), value: inputFocused)
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .frame(maxWidth: Self.readableWidth)
    }

    /// Shown under the composer whenever questions use the reader's ChatGPT plan.
    private var planUsage: some View {
        HStack(spacing: 4) {
            Text("Using ChatGPT plan")
            Text("·")
            Link("Manage usage", destination: ChatGPTAccount.usageURL)
                .foregroundStyle(.primary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 6)
        .padding(.bottom, reader.assistantExpanded ? 14 : 10)
    }

    // MARK: History

    private var history: some View {
        let threads = reader.state.liveChats
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                PanelIconButton(symbol: "chevron.left", label: "Back") { reader.assistantShowsHistory = false }
                Text("Conversations").font(.headline)
                Spacer()
                HStack(spacing: 4) {
                    PanelIconButton(symbol: "trash", label: "Delete All Conversations") { confirmingClearAll = true }
                        .disabled(threads.isEmpty)
                    PanelIconButton(symbol: "square.and.pencil", label: "New Conversation") {
                        chat.newThread()
                        reader.assistantShowsHistory = false
                        openedFromHistory = false
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
                                       open: { chat.open(t); openedFromHistory = true; reader.assistantShowsHistory = false },
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

/// Compact: a floating card. Expanded: fills the window below the header, flush with its edges.
private struct PanelSurface: ViewModifier {
    let expanded: Bool
    let theme: ReaderTheme

    func body(content: Content) -> some View {
        if expanded {
            content
                .background(theme.backgroundColor)
                .overlay(alignment: .top) { Rectangle().fill(.primary.opacity(0.08)).frame(height: 0.5) }
        } else {
            content
                .clipShape(.rect(cornerRadius: 26))
                .readerPanelSurface(theme)
        }
    }
}

struct AssistantAvatar: View {
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(LinearGradient(colors: [Color(hex: "#3A3A3C"), Color(hex: "#0D0D0D")],
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
                    if isCurrent { Text("· Open").foregroundStyle(.primary) }
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
            RoundedRectangle(cornerRadius: 2).fill(.primary.opacity(0.3)).frame(width: 3)
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
            RoundedRectangle(cornerRadius: 1.5).fill(.primary.opacity(0.3)).frame(width: 3)
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
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ErrorCard: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("ChatGPT couldn’t answer", systemImage: "exclamationmark.triangle.fill")
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
                    .background(.primary.opacity(0.07), in: .rect(cornerRadius: 18))
            }
        } else {
            MarkdownText(text: message.text, rendersDiagrams: !streaming)
        }
    }
}

/// Renders ChatGPT's Markdown: paragraphs, headings, lists, tables, quotes and code.
struct MarkdownText: View {
    let text: String
    var rendersDiagrams = true

    @AppStorage(ChatFont.key) private var face = ChatFont.standard
    @AppStorage(ChatTextSize.key) private var size = ChatTextSize.standard

    private var scale: CGFloat { size / ChatTextSize.standard }
    private func replyFont(_ points: CGFloat) -> Font { face.font(points * scale) }
    /// A paragraph that is only bold text acts as a section heading.
    private var blocks: [Markdown.Block] {
        Markdown.blocks(text).map { block in
            if case .paragraph(let t) = block, let m = t.wholeMatch(of: /\*\*([^*]+)\*\*:?/) {
                return .heading(3, String(m.1))
            }
            return block
        }
    }
    /// Extra space between lines, for a line height of 1.6 at body size.
    private var leading: CGFloat { 5.6 * scale }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let t):
                    Text(Markdown.attributed(t)).font(replyFont(level <= 2 ? 18 : 16.5).weight(.medium))
                        .foregroundStyle(Color.primary.mix(with: .accentColor, by: 0.18))
                        .padding(.top, 6)
                case .paragraph(let t):
                    Text(Markdown.attributed(t)).font(replyFont(16)).lineSpacing(leading)
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
                            .font(replyFont(16).italic()).lineSpacing(leading).foregroundStyle(.primary.opacity(0.78))
                    }
                case .list(let ordered, let items):
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(ordered ? "\(i + 1)." : "•").font(replyFont(16)).foregroundStyle(.secondary).monospacedDigit()
                                Text(Markdown.attributed(item)).font(replyFont(16)).lineSpacing(leading)
                            }
                        }
                    }
                case .table(let header, let rows):
                    Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 7) {
                        GridRow {
                            ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                                Text(Markdown.attributed(cell)).font(replyFont(15).weight(.medium))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            Divider().gridCellUnsizedAxes(.horizontal)
                            GridRow {
                                ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                    Text(Markdown.attributed(cell)).font(replyFont(15)).lineSpacing(3.5 * scale)
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

/// Cards for what ChatGPT did in the app, each with Undo while the session lasts.
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
                            .foregroundStyle(.primary)
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }
}

/// Starts Sign in with ChatGPT, shown in place of the composer while signed out.
struct ChatGPTSignInCard: View {
    var compact = false
    private var account: ChatGPTAccount { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Use your ChatGPT plan").font(.headline)
            Text("Ask about your books with your ChatGPT Plus or Pro plan. You sign in on OpenAI’s website; Books never sees your password.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let problem = account.problem, account.status != .signingIn {
                Text(problem).font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if account.status == .signingIn {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Finish signing in in your browser…").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { account.cancelSignIn() }.controlSize(.small)
                }
            } else {
                ContinueWithChatGPTButton { account.signIn() }
            }
        }
        .padding(compact ? 14 : 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.08), lineWidth: 1))
    }
}

/// The black "Continue with ChatGPT" button from OpenAI's sign-in guidelines.
struct ContinueWithChatGPTButton: View {
    let action: () -> Void

    var body: some View {
        ChatGPTPrimaryButton(title: "Continue with ChatGPT", action: action)
    }
}

/// Shown when ChatGPT reports a usage limit, following OpenAI's guidelines: ChatGPT identity, Manage usage first.
private struct UsageLimitCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                AssistantAvatar(size: 20)
                Text("ChatGPT").font(.subheadline.weight(.semibold))
            }
            Text("Usage limit reached").font(.title3.weight(.semibold))
            Text(ChatGPTError.usageLimit.localizedDescription)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                ChatGPTPrimaryButton(title: "Manage usage") { NSWorkspace.shared.open(ChatGPTAccount.usageURL) }
                Button("Try again") { withAnimation(.snappy) { ChatGPTAccount.shared.usageLimitReached = false } }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.08), lineWidth: 1))
    }
}

/// Black capsule button in OpenAI's sign-in style; white in dark mode.
struct ChatGPTPrimaryButton: View {
    let title: String
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(scheme == .dark ? Color.black : Color.white)
                .padding(.horizontal, 16)
                .frame(height: 32)
                .background(Capsule().fill(scheme == .dark ? Color.white : Color.black))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
