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
        let scope = scope
        let model = model
        task = Task {
            let context = await reader.context(for: scope)
            let system = Self.systemPrompt(reader: reader)
            let prompt = Self.prompt(context: context, scope: scope, passage: passage, history: history, question: question)
            do {
                for try await event in ClaudeService.stream(prompt: prompt, system: system, model: model) {
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
        guard thread != nil, !text.isEmpty else { return }
        thread!.messages.append(ChatMessage(role: .assistant, text: text))
        thread!.updated = Date()
        persist()
    }

    private func persist() {
        guard let thread, let reader else { return }
        reader.library.update(reader.book.id) { s in
            if let i = s.chats.firstIndex(where: { $0.id == thread.id }) { s.chats[i] = thread } else { s.chats.append(thread) }
        }
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

struct ClaudePanel: View {
    let reader: ReaderModel
    @Bindable var chat: ClaudeChat
    let theme: ReaderTheme
    @State private var showHistory = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            if showHistory {
                history
            } else {
                conversation
                composer
            }
        }
        .frame(width: 390)
        .glassEffect(.regular.tint(theme.backgroundColor.opacity(0.6)), in: .rect(cornerRadius: 26))
        .readerOverlay()
        .shadow(color: .black.opacity(0.12), radius: 30, y: 10)
        .onChange(of: reader.claudeDraft) { _, seed in
            if let seed { chat.begin(with: seed); showHistory = false; reader.claudeDraft = nil; inputFocused = true }
        }
        .onAppear {
            if let seed = reader.claudeDraft { chat.begin(with: seed); reader.claudeDraft = nil }
            inputFocused = true
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [Color(hex: "#D97757"), Color(hex: "#C15F3C")], startPoint: .top, endPoint: .bottom))
            Text("Ask Claude").font(.headline)
            Spacer()
            Menu {
                Picker("Model", selection: $chat.model) {
                    ForEach(ClaudeModel.allCases) { m in
                        Text("\(m.name) — \(m.detail)").tag(m)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Text(chat.model.name).font(.callout.weight(.medium))
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .fixedSize()
            Button { withAnimation(.snappy) { showHistory.toggle() } } label: {
                Image(systemName: showHistory ? "bubble.left.and.bubble.right.fill" : "clock.arrow.circlepath")
            }
            .buttonStyle(.glass)
            .help("Past conversations")
            Button { chat.newThread(); showHistory = false; inputFocused = true } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(.glass)
                .help("New conversation")
            Button { withAnimation(.spring(duration: 0.35)) { reader.showClaude = false } } label: { Image(systemName: "xmark") }
                .buttonStyle(.glass)
                .help("Close")
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

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
                        MessageView(message: m, onCopy: { copy(m.text) }, onSaveNote: m.role == .assistant ? { saveNote(m.text) } : nil)
                            .id(m.id)
                    }
                    if chat.isStreaming {
                        MessageView(message: ChatMessage(role: .assistant, text: chat.streamingText), streaming: true)
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
            .onChange(of: chat.thread?.messages.count) { _, _ in
                withAnimation(.snappy) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(chat.thread?.passage == nil ? "Ask anything about what you’re reading." : "What would you like to know about this passage?")
                .font(.system(.title3, design: .serif))
                .foregroundStyle(.secondary)
            FlowLayout(spacing: 8) {
                ForEach(ClaudeQuickAction.allCases) { action in
                    if chat.thread?.passage != nil || action != .define {
                        Button {
                            chat.send(action.prompt(hasPassage: chat.thread?.passage != nil))
                        } label: {
                            Label(action.title, systemImage: action.symbol).font(.callout)
                        }
                        .buttonStyle(.glass)
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    private var composer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Text("Context").font(.caption).foregroundStyle(.secondary)
                Picker("Context", selection: $chat.scope) {
                    ForEach(ClaudeScope.allCases.filter { $0 != .passage || chat.thread?.passage != nil }, id: \.self) { s in
                        Text(s == .passage ? "Passage only" : s.label).tag(s)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask a question…", text: $chat.input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($inputFocused)
                    .onSubmit { chat.send() }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .rect(cornerRadius: 18))
                if chat.isStreaming {
                    Button { chat.cancel() } label: { Image(systemName: "stop.fill").frame(width: 18, height: 18) }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                        .help("Stop")
                } else {
                    Button { chat.send() } label: { Image(systemName: "arrow.up").fontWeight(.semibold).frame(width: 18, height: 18) }
                        .buttonStyle(.glassProminent)
                        .tint(Color(hex: "#C96442"))
                        .controlSize(.large)
                        .disabled(chat.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .padding(14)
    }

    private var history: some View {
        let threads = reader.state.liveChats
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if threads.isEmpty {
                    Text("No conversations yet.").foregroundStyle(.secondary).padding(.top, 30).frame(maxWidth: .infinity)
                }
                ForEach(threads) { t in
                    Button {
                        chat.open(t)
                        withAnimation(.snappy) { showHistory = false }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(t.title).font(.callout.weight(.medium)).lineLimit(2)
                            HStack {
                                Text(t.updated, style: .relative)
                                Text("·")
                                Text("\(t.messages.count) messages")
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Delete Conversation", role: .destructive) { chat.delete(t) }
                    }
                }
            }
            .padding(16)
        }
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
                    HStack(spacing: 4) {
                        if let onCopy {
                            Button(action: onCopy) { Image(systemName: "doc.on.doc") }.help("Copy")
                        }
                        if let onSaveNote {
                            Button(action: onSaveNote) { Image(systemName: "note.text.badge.plus") }.help("Save to Notes")
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .opacity(hovering ? 1 : 0)
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
