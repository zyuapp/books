import AppKit
import SwiftUI
import WebKit

/// Reflowable books: one spine document at a time in a WKWebView, paginated with CSS columns.
struct WebReaderView: NSViewRepresentable {
    let model: ReaderModel
    let publication: Publication
    let isDark: Bool
    let prefs: ReaderPreferences

    func makeCoordinator() -> WebEngine {
        WebEngine(model: model, publication: publication)
    }

    func makeNSView(context: Context) -> ReaderWebView {
        let engine = context.coordinator
        engine.isDark = isDark
        model.engine = engine
        engine.start()
        return engine.webView
    }

    func updateNSView(_ view: ReaderWebView, context: Context) {
        let engine = context.coordinator
        if engine.isDark != isDark || engine.lastPrefs != prefs {
            engine.isDark = isDark
            engine.applySettings()
        }
    }
}

@MainActor
final class WebEngine: NSObject, ReaderEngine, WKNavigationDelegate {
    let webView: ReaderWebView
    private let publication: Publication
    private weak var model: ReaderModel?
    private var currentIndex = -1
    private var pendingTarget: [String: Any]?
    private var pendingFind: (query: String, occurrence: Int)?
    private var lastTextOffset: Int?
    private var isReady = false
    private var loadID = 0
    var isDark = false
    var lastPrefs: ReaderPreferences?

    private static let readerScript: String = {
        guard let url = Bundle.main.url(forResource: "reader", withExtension: "js"),
              let js = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return js
    }()

    init(model: ReaderModel, publication: Publication) {
        self.model = model
        self.publication = publication
        let config = WKWebViewConfiguration()
        let handler = WeakMessageHandler()
        config.userContentController.add(handler, contentWorld: .defaultClient, name: "reader")
        config.suppressesIncrementalRendering = true
        config.preferences.isTextInteractionEnabled = true
        // Book scripts never run; the reader script lives in an isolated world that only sees the DOM.
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        webView = ReaderWebView(frame: .zero, configuration: config)
        super.init()
        handler.engine = self
        webView.navigationDelegate = self
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.alphaValue = 0
        webView.underPageBackgroundColor = .clear
        webView.setValue(false, forKey: "drawsBackground")
        webView.engine = self
    }

    /// Blocks every network request a book makes (trackers, remote fonts, exfiltration); books render from local files only.
    private static func offlineRules() async -> WKContentRuleList? {
        let json = #"""
        [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^ftp://"},"action":{"type":"block"}}]
        """#
        do {
            return try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "books-offline", encodedContentRuleList: json)
        } catch {
            assertionFailure("Offline content rules failed to compile: \(error)")
            return nil
        }
    }

    func start() {
        Task { [weak self] in
            let rules = await Self.offlineRules()
            guard let self else { return }
            if let rules { webView.configuration.userContentController.add(rules) }
            startLoading()
        }
    }

    private func startLoading() {
        applySettings()
        let start = model?.restoreTarget() ?? Locator(index: 0)
        go(to: start, fragment: nil, atEnd: false)
    }

    // MARK: Configuration

    private var prefs: ReaderPreferences { ReaderSettings.shared.prefs }

    private func config(fixed: Bool) -> [String: Any] {
        let p = prefs
        let theme = p.theme.resolved(dark: isDark)
        let font = ReaderFont.named(p.fontID)
        return [
            "loadID": loadID,
            "layout": fixed ? "fixed" : p.layout.rawValue,
            "spread": p.spread.rawValue,
            "marginMin": p.margin,
            "vmargin": 82,
            "maxWidth": Int(p.fontSize * 36 + p.margin * 2),
            "size": p.fontSize,
            "lineHeight": p.lineHeight,
            "font": font.css,
            "justify": p.justify,
            "hyphenate": p.hyphenate,
            "bg": theme.background,
            "fg": theme.foreground,
            "secondary": theme.secondary,
            "accent": theme.accent,
            "dark": theme.isDark,
        ]
    }

    private var currentIsFixed: Bool {
        publication.spine.indices.contains(currentIndex) && publication.spine[currentIndex].fixedLayout
    }

    private func installUserScripts(fixed: Bool) {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        let json = Self.json(config(fixed: fixed))
        controller.addUserScript(WKUserScript(source: "window.__readerConfig = \(json);",
                                              injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
        controller.addUserScript(WKUserScript(source: Self.readerScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
    }

    func applySettings() {
        lastPrefs = prefs
        webView.isPaginated = prefs.layout == .paginated && !currentIsFixed
        installUserScripts(fixed: currentIsFixed)
        if isReady { run("Reader.configure(\(Self.json(config(fixed: currentIsFixed))))") }
    }

    // MARK: Navigation

    func go(to locator: Locator, fragment: String?, atEnd: Bool) {
        var target: [String: Any] = ["progression": locator.progression]
        if let fragment { target["fragment"] = fragment }
        if atEnd { target["end"] = true }
        if let off = locator.textOffset, fragment == nil, !atEnd { target["textOffset"] = off }
        let index = min(max(0, locator.index), publication.spine.count - 1)
        if index == currentIndex && isReady {
            run("Reader.go(\(Self.json(target)))")
        } else {
            load(index, target: target)
        }
    }

    private func load(_ index: Int, target: [String: Any]) {
        currentIndex = index
        pendingTarget = target
        isReady = false
        loadID += 1
        let fixed = currentIsFixed
        webView.isPaginated = prefs.layout == .paginated && !fixed
        installUserScripts(fixed: fixed)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            webView.animator().alphaValue = 0
        }
        webView.loadFileURL(publication.spine[index].url, allowingReadAccessTo: publication.rootDirectory)
    }

    func next() { turn(forward: true) }
    func previous() { turn(forward: false) }

    private var turnQueue: [Bool] = []
    private var isTurning = false

    /// Turns run one at a time; presses made during a turn are queued.
    private func turn(forward: Bool) {
        turnQueue.append(forward)
        if turnQueue.count > 4 { turnQueue.removeFirst(turnQueue.count - 4) }
        if isTurning { return }
        isTurning = true
        Task {
            while !turnQueue.isEmpty {
                let dir = turnQueue.removeFirst()
                await waitUntilReady()
                _ = await instantTurn(dir)
            }
            isTurning = false
        }
    }

    /// Turns one page, crossing into the next or previous chapter. False at the book's edge.
    private func instantTurn(_ forward: Bool) async -> Bool {
        if isReady {
            let moved = (try? await js("Reader.\(forward ? "next" : "prev")()")) as? Bool
            if moved == true { return true }
        }
        let target = forward ? currentIndex + 1 : currentIndex - 1
        guard publication.spine.indices.contains(target) else { return false }
        load(target, target: forward ? ["progression": 0] : ["end": true])
        await waitUntilReady()
        return true
    }

    private var readyWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    /// Waits for the current document's "ready", giving up after a few seconds so a broken chapter can't wedge turning.
    private func waitUntilReady(timeout: Double = 5) async {
        if isReady { return }
        let id = UUID()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            readyWaiters[id] = c
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.readyWaiters.removeValue(forKey: id)?.resume()
            }
        }
    }

    private func resumeReadyWaiters() {
        let waiters = readyWaiters
        readyWaiters = [:]
        waiters.values.forEach { $0.resume() }
    }

    func refreshHighlights() {
        guard isReady, let model else { return }
        let list: [[String: Any]] = model.state.liveHighlights.compactMap { h in
            guard h.locator.index == currentIndex, let r = h.range else { return nil }
            return ["id": h.id.uuidString, "start": r.start, "end": r.end, "color": h.color.rawValue, "note": h.note ?? ""]
        }
        run("Reader.setHighlights(\(Self.json(list)))")
    }

    func reveal(_ result: SearchResult, query: String) {
        if result.locator.index == currentIndex && isReady {
            run("Reader.find(\(Self.json(query)), \(result.occurrence))")
        } else {
            pendingFind = (query, result.occurrence)
            load(result.locator.index, target: ["progression": result.locator.progression])
        }
    }

    func clearSelection() {
        run("Reader.clearSelection()")
    }

    func currentSectionText() async -> String {
        (try? await js("Reader.chapterText()") as? String) ?? ""
    }

    func currentPageText() async -> String {
        (try? await js("Reader.visibleText()") as? String) ?? ""
    }

    func currentSnippet() async -> String {
        let offset = lastTextOffset ?? 0
        return (try? await js("Reader.snippetAt(\(offset))") as? String) ?? ""
    }

    // MARK: Messages

    func handle(_ body: [String: Any]) {
        guard let model, let type = body["type"] as? String else { return }
        // Ignore stragglers from the document being replaced.
        if let lid = body["lid"] as? Int, lid != loadID { return }
        switch type {
        case "ready":
            isReady = true
            if let target = pendingTarget {
                run("Reader.go(\(Self.json(target)))") { [weak self] in self?.resumeReadyWaiters() }
            } else {
                resumeReadyWaiters()
            }
            focusContent(onlyIfUnfocused: true)
            pendingTarget = nil
            refreshHighlights()
            if let find = pendingFind {
                run("Reader.find(\(Self.json(find.query)), \(find.occurrence))")
                pendingFind = nil
            }
            if webView.alphaValue < 1 {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.22
                    webView.animator().alphaValue = 1
                }
            }
        case "location":
            let offset = body["textOffset"] as? Int
            lastTextOffset = offset
            let locator = Locator(index: currentIndex, progression: body["progression"] as? Double ?? 0, textOffset: offset)
            model.engineDidMove(to: locator, page: body["page"] as? Int ?? 0, pageCount: body["pageCount"] as? Int ?? 1,
                                atEnd: body["atEnd"] as? Bool ?? false)
        case "selection":
            guard let text = body["text"] as? String, let rect = Self.rect(body["bounds"]) ?? Self.rect(body["rect"]) else { return }
            let range = (body["start"] as? Int).flatMap { s in (body["end"] as? Int).map { TextRange(start: s, end: $0) } }
            model.selection = ReaderSelection(text: text, rect: rect, range: range)
        case "selectionCleared":
            if model.selection?.highlightID == nil { model.selection = nil }
        case "highlightTapped":
            guard let id = (body["id"] as? String).flatMap(UUID.init(uuidString:)),
                  let h = model.state.liveHighlights.first(where: { $0.id == id }),
                  let rect = Self.rect(body["rect"]) else { return }
            model.selection = ReaderSelection(text: h.text, rect: rect, range: h.range, highlightID: id)
        case "link":
            guard let s = body["url"] as? String, let url = URL(string: s) else { return }
            if body["noteRef"] as? Bool == true, let fragment = url.fragment, let rect = Self.rect(body["rect"]),
               url.standardizedFileURL.path.hasPrefix(publication.rootDirectory.standardizedFileURL.path + "/"),
               let text = Self.noteText(in: url, id: fragment.removingPercentEncoding ?? fragment) {
                model.footnote = FootnotePopup(text: text, rect: rect, link: url)
            } else {
                model.openLink(url)
            }
        case "external":
            if let s = body["url"] as? String, let url = URL(string: s), Self.isSafeExternal(url) { NSWorkspace.shared.open(url) }
        case "tap":
            if model.footnote != nil { model.footnote = nil; return }
            model.toggleChrome()
        case "footnote":
            guard let text = body["text"] as? String, let rect = Self.rect(body["rect"]) else { return }
            model.footnote = FootnotePopup(text: text, rect: rect)
        default: break
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        if url.isFileURL { return action.navigationType == .linkActivated ? .cancel : .allow }
        if url.scheme == "about" { return .allow }
        if action.navigationType == .linkActivated, Self.isSafeExternal(url) { NSWorkspace.shared.open(url) }
        return .cancel
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { loadFailed() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { loadFailed() }

    private func loadFailed() {
        webView.alphaValue = 1
        resumeReadyWaiters()
    }

    /// Runs reader script in the isolated content world.
    private func js(_ source: String) async throws -> Any? {
        try await webView.evaluateJavaScript(source, contentWorld: .defaultClient)
    }

    private func run(_ source: String, then done: (() -> Void)? = nil) {
        webView.evaluateJavaScript(source, in: nil, in: .defaultClient) { _ in done?() }
    }

    func focusContent() { focusContent(onlyIfUnfocused: false) }

    private func focusContent(onlyIfUnfocused: Bool) {
        guard let window = webView.window else { return }
        if onlyIfUnfocused, window.firstResponder is NSText { return }
        window.makeFirstResponder(webView)
    }

    func waitUntilContentReady() async { await waitUntilReady() }

    func locate(_ quote: String) async -> HighlightTarget? {
        await waitUntilReady()
        guard let r = try? await js("Reader.locate(\(Self.json(quote)))") as? [String: Any],
              let start = (r["start"] as? NSNumber)?.intValue, let end = (r["end"] as? NSNumber)?.intValue else { return nil }
        return HighlightTarget(text: r["text"] as? String ?? quote, index: currentIndex,
                               progression: (r["progression"] as? NSNumber)?.doubleValue ?? 0,
                               range: TextRange(start: start, end: end))
    }

    func fragmentOffsets(_ ids: [String]) async -> [String: Int] {
        guard isReady else { return [:] }
        let result = try? await js("Reader.fragmentOffsets(\(Self.json(ids)))")
        return (result as? [String: Any])?.compactMapValues { ($0 as? NSNumber)?.intValue } ?? [:]
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let index = max(0, currentIndex)
        currentIndex = -1
        go(to: model?.location ?? Locator(index: index), fragment: nil, atEnd: false)
    }

    // MARK: Helpers

    static func json(_ value: Any) -> String {
        if let s = value as? String {
            let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
            return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
        }
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Text of the element with `id` in another spine document, for footnote popups.
    static func noteText(in url: URL, id: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: url.path)) else { return nil }
        let html = String(decoding: data, as: UTF8.self)
        let escaped = NSRegularExpression.escapedPattern(for: id)
        guard let open = html.range(of: "<([a-zA-Z0-9]+)[^>]*\\b(id|name)=[\"']\(escaped)[\"'][^>]*>", options: .regularExpression)
        else { return nil }
        let tag = String(html[open].dropFirst().prefix { $0.isLetter || $0.isNumber })
        // Walk to the matching close tag of the target element.
        var depth = 1
        var cursor = open.upperBound
        let pattern = try! NSRegularExpression(pattern: "<(/?)\(tag)\\b[^>]*?(/?)>", options: .caseInsensitive)
        var end = html.endIndex
        while depth > 0, let m = pattern.firstMatch(in: html, range: NSRange(cursor..<html.endIndex, in: html)),
              let r = Range(m.range, in: html) {
            let closing = !(Range(m.range(at: 1), in: html).map { html[$0].isEmpty } ?? true)
            let selfClosing = !(Range(m.range(at: 2), in: html).map { html[$0].isEmpty } ?? true)
            if closing { depth -= 1 } else if !selfClosing { depth += 1 }
            cursor = r.upperBound
            if depth == 0 { end = r.lowerBound }
        }
        func blocks(_ fragment: Substring) -> String {
            fragment.replacingOccurrences(of: "</(p|div|h[1-6]|li|dt|dd|section|aside|blockquote)>|<br[^>]*>",
                                          with: "\n", options: [.regularExpression, .caseInsensitive])
        }
        var text = TextExtractor.plainText(fromHTML: "<body>" + blocks(html[open.upperBound..<end]) + "</body>")
        if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 4 {
            // Anchor-only targets: take the text that follows, up to the next anchor.
            var rest = String(html[end...].prefix(4000))
            if let next = rest.range(of: "\\b(id|name)=[\"']", options: .regularExpression) { rest = String(rest[..<next.lowerBound]) }
            text += " " + TextExtractor.plainText(fromHTML: "<body>" + blocks(Substring(rest)) + "</body>")
        }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : String(joined.prefix(2000))
    }

    /// Books may only open web pages and mail drafts, never other apps' URL schemes.
    static func isSafeExternal(_ url: URL) -> Bool {
        ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "")
    }

    static func rect(_ any: Any?) -> CGRect? {
        guard let d = any as? [String: Any],
              let x = d["x"] as? Double, let y = d["y"] as? Double,
              let w = d["width"] as? Double, let h = d["height"] as? Double else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var engine: WebEngine?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        MainActor.assumeIsolated { engine?.handle(body) }
    }
}

/// Swallows wheel and trackpad scrolling in paged layouts (only the arrow keys turn pages), plus reader items in the context menu.
final class ReaderWebView: WKWebView {
    weak var engine: WebEngine?
    var isPaginated = true

    private var model: ReaderModel? { MainActor.assumeIsolated { engine.flatMap { $0.modelRef } } }

    override var acceptsFirstResponder: Bool { true }

    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let model, isUnderOverlay(point, rects: model.overlayRects) { return nil }
        return super.hitTest(point)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil else { return }
        // WebKit consumes wheel events internally, so intercept them before dispatch.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            guard let self, event.window === self.window, self.isPaginated else { return event }
            let p = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(p), !self.isUnderOverlay(self.superview?.convert(event.locationInWindow, from: nil) ?? p,
                                                                rects: self.model?.overlayRects ?? []) else { return event }
            return nil
        }
    }

    override func removeFromSuperview() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        super.removeFromSuperview()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(where: { $0.userInfo?["reader"] != nil }) {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                           owner: self, userInfo: ["reader": true]))
        }
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        guard model?.selection != nil else { return }
        let items: [(String, String, Selector)] = [
            ("Ask Claude", "sparkles", #selector(menuAskClaude)),
            ("Highlight", "highlighter", #selector(menuHighlight)),
            ("Add Note", "note.text.badge.plus", #selector(menuNote)),
        ]
        for (i, item) in items.enumerated() {
            let mi = NSMenuItem(title: item.0, action: item.2, keyEquivalent: "")
            mi.image = NSImage(systemSymbolName: item.1, accessibilityDescription: nil)
            mi.target = self
            menu.insertItem(mi, at: i)
        }
        menu.insertItem(.separator(), at: items.count)
    }

    @objc private func menuAskClaude() { model?.askClaude(action: nil) }
    @objc private func menuHighlight() { model?.highlightSelection(.yellow) }
    @objc private func menuNote() { model?.addNoteToSelection() }
}

extension WebEngine {
    var modelRef: ReaderModel? { model }
}
