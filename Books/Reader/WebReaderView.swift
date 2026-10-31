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
        config.userContentController.add(handler, name: "reader")
        config.suppressesIncrementalRendering = true
        config.preferences.isTextInteractionEnabled = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
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

    func start() {
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
            "vmargin": 64,
            "maxWidth": Int(p.fontSize * 36 + p.margin * 2),
            "size": p.fontSize,
            "lineHeight": p.lineHeight,
            "font": font.css,
            "justify": p.justify,
            "hyphenate": p.hyphenate,
            "animate": p.pageTurnAnimation,
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
                                              injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: Self.readerScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    }

    func applySettings() {
        lastPrefs = prefs
        webView.isPaginated = prefs.layout == .paginated && !currentIsFixed
        installUserScripts(fixed: currentIsFixed)
        if isReady { webView.evaluateJavaScript("Reader.configure(\(Self.json(config(fixed: currentIsFixed))))") }
    }

    // MARK: Navigation

    func go(to locator: Locator, fragment: String?, atEnd: Bool) {
        var target: [String: Any] = ["progression": locator.progression]
        if let fragment { target["fragment"] = fragment }
        if atEnd { target["end"] = true }
        if let off = locator.textOffset, fragment == nil, !atEnd { target["textOffset"] = off }
        let index = min(max(0, locator.index), publication.spine.count - 1)
        if index == currentIndex && isReady {
            webView.evaluateJavaScript("Reader.go(\(Self.json(target)))")
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

    func next() {
        guard isReady else { return }
        webView.evaluateJavaScript("Reader.next()") { [weak self] result, error in
            guard let self, (result as? Bool) == false else { return }
            if self.currentIndex + 1 < self.publication.spine.count {
                self.load(self.currentIndex + 1, target: ["progression": 0])
            }
        }
    }

    func previous() {
        guard isReady else { return }
        webView.evaluateJavaScript("Reader.prev()") { [weak self] result, _ in
            guard let self, (result as? Bool) == false else { return }
            if self.currentIndex > 0 { self.load(self.currentIndex - 1, target: ["end": true]) }
        }
    }

    func refreshHighlights() {
        guard isReady, let model else { return }
        let list: [[String: Any]] = model.state.liveHighlights.compactMap { h in
            guard h.locator.index == currentIndex, let r = h.range else { return nil }
            return ["id": h.id.uuidString, "start": r.start, "end": r.end, "color": h.color.rawValue, "note": h.note ?? ""]
        }
        webView.evaluateJavaScript("Reader.setHighlights(\(Self.json(list)))")
    }

    func reveal(_ result: SearchResult, query: String) {
        if result.locator.index == currentIndex && isReady {
            webView.evaluateJavaScript("Reader.find(\(Self.json(query)), \(result.occurrence))")
        } else {
            pendingFind = (query, result.occurrence)
            load(result.locator.index, target: ["progression": result.locator.progression])
        }
    }

    func clearSelection() {
        webView.evaluateJavaScript("Reader.clearSelection()")
    }

    func currentSectionText() async -> String {
        (try? await webView.evaluateJavaScript("Reader.chapterText()") as? String) ?? ""
    }

    func currentSnippet() async -> String {
        let offset = lastTextOffset ?? 0
        return (try? await webView.evaluateJavaScript("Reader.snippetAt(\(offset))") as? String) ?? ""
    }

    // MARK: Messages

    func handle(_ body: [String: Any]) {
        guard let model, let type = body["type"] as? String else { return }
        // Ignore stragglers from the document being replaced.
        if let lid = body["lid"] as? Int, lid != loadID { return }
        switch type {
        case "ready":
            isReady = true
            if let target = pendingTarget { webView.evaluateJavaScript("Reader.go(\(Self.json(target)))") }
            pendingTarget = nil
            refreshHighlights()
            if let find = pendingFind {
                webView.evaluateJavaScript("Reader.find(\(Self.json(find.query)), \(find.occurrence))")
                pendingFind = nil
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                webView.animator().alphaValue = 1
            }
            webView.window?.makeFirstResponder(webView)
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
               let text = Self.noteText(in: url, id: fragment.removingPercentEncoding ?? fragment) {
                model.footnote = FootnotePopup(text: text, rect: rect, link: url)
            } else {
                model.openLink(url)
            }
        case "external":
            if let s = body["url"] as? String, let url = URL(string: s) { NSWorkspace.shared.open(url) }
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
        if action.navigationType == .linkActivated { NSWorkspace.shared.open(url) }
        return .cancel
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

/// Keyboard and trackpad page turning, plus reader items in the context menu.
final class ReaderWebView: WKWebView {
    weak var engine: WebEngine?
    var isPaginated = true
    private var accumulated = CGSize.zero
    private var gestureFired = false
    private var lastWheelTurn = Date.distantPast

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
        // WebKit consumes key and wheel events internally, so intercept them before dispatch.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel, .mouseMoved]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            switch event.type {
            case .keyDown:
                guard let responder = self.window?.firstResponder as? NSView, responder === self || responder.isDescendant(of: self)
                else { return event }
                return self.handleKey(event) ? nil : event
            case .scrollWheel:
                let p = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(p), self.isPaginated else { return event }
                return self.handleWheel(event) ? nil : event
            case .mouseMoved:
                let p = self.convert(event.locationInWindow, from: nil)
                if self.bounds.contains(p), p.y > self.bounds.height - 90 || p.y < 90 { self.model?.pokeChrome() }
                return event
            default: return event
            }
        }
    }

    override func removeFromSuperview() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        super.removeFromSuperview()
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let model else { return false }
        if JumpKeys.handle(event, model: model) { return true }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        let rtl = model.publication?.rightToLeft == true
        switch Int(event.keyCode) {
        case 123: rtl ? model.nextPage() : model.previousPage()
        case 124: rtl ? model.previousPage() : model.nextPage()
        case 125 where isPaginated, 121: model.nextPage()
        case 126 where isPaginated, 116: model.previousPage()
        case 49: event.modifierFlags.contains(.shift) ? model.previousPage() : model.nextPage()
        case 53:
            if model.selection != nil || model.footnote != nil {
                model.selection = nil
                model.footnote = nil
                engine?.clearSelection()
            } else if model.showClaude || model.panel != nil {
                withAnimation(.spring(duration: 0.35)) { model.showClaude = false; model.panel = nil }
            } else { return false }
        default: return false
        }
        return true
    }

    private func handleWheel(_ event: NSEvent) -> Bool {
        guard let model else { return false }
        if !event.momentumPhase.isEmpty { return true }
        if event.phase.isEmpty {
            guard Date().timeIntervalSince(lastWheelTurn) > 0.28 else { return true }
            let d = abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) ? event.scrollingDeltaY : event.scrollingDeltaX
            if d < 0 { model.nextPage() } else if d > 0 { model.previousPage() }
            lastWheelTurn = Date()
            return true
        }
        if event.phase.contains(.began) { accumulated = .zero; gestureFired = false }
        accumulated.width += event.scrollingDeltaX
        accumulated.height += event.scrollingDeltaY
        guard !gestureFired else { return true }
        let rtl = model.publication?.rightToLeft == true
        if accumulated.width < -45 { gestureFired = true; rtl ? model.previousPage() : model.nextPage() }
        else if accumulated.width > 45 { gestureFired = true; rtl ? model.nextPage() : model.previousPage() }
        else if accumulated.height < -70 { gestureFired = true; model.nextPage() }
        else if accumulated.height > 70 { gestureFired = true; model.previousPage() }
        return true
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
