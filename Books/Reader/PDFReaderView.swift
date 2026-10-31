import AppKit
import CoreImage
import PDFKit
import SwiftUI

struct PDFReaderView: NSViewRepresentable {
    let model: ReaderModel
    let publication: Publication
    let isDark: Bool
    let prefs: ReaderPreferences

    func makeCoordinator() -> PDFEngine { PDFEngine(model: model, publication: publication) }

    func makeNSView(context: Context) -> ReaderPDFView {
        let engine = context.coordinator
        model.engine = engine
        engine.isDark = isDark
        engine.start()
        return engine.pdfView
    }

    func updateNSView(_ view: ReaderPDFView, context: Context) {
        let engine = context.coordinator
        if engine.isDark != isDark || engine.lastPrefs != prefs {
            engine.isDark = isDark
            engine.applySettings()
        }
    }
}

@MainActor
final class PDFEngine: NSObject, ReaderEngine {
    let pdfView = ReaderPDFView()
    private let publication: Publication
    private weak var model: ReaderModel?
    private let document: PDFDocument?
    private var observers: [NSObjectProtocol] = []
    private var suppressJumpRecording = false
    var isDark = false
    var lastPrefs: ReaderPreferences?

    private static let highlightTag = "com.zyuapp.books.highlight"

    init(model: ReaderModel, publication: Publication) {
        self.model = model
        self.publication = publication
        document = PDFDocument(url: publication.sourceURL)
        super.init()
        pdfView.engine = self
        pdfView.autoScales = true
        pdfView.displaysPageBreaks = true
        pdfView.pageShadowsEnabled = true
        pdfView.document = document
    }

    func start() {
        applySettings()
        refreshHighlights()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pageChanged() }
        })
        observers.append(center.addObserver(forName: .PDFViewSelectionChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.selectionChanged() }
        })
        let target = model?.restoreTarget().index ?? 0
        DispatchQueue.main.async { [weak self] in
            guard let self, let page = self.document?.page(at: min(target, max(0, (self.document?.pageCount ?? 1) - 1))) else { return }
            self.suppressJumpRecording = true
            self.pdfView.go(to: page)
            self.suppressJumpRecording = false
            self.pageChanged()
        }
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    func applySettings() {
        let p = ReaderSettings.shared.prefs
        lastPrefs = p
        let theme = p.theme.resolved(dark: isDark)
        let width = pdfView.bounds.width
        let twoUp = p.spread == .double || (p.spread == .auto && width > 1400)
        switch p.layout {
        case .paginated: pdfView.displayMode = twoUp ? .twoUp : .singlePage
        case .scroll: pdfView.displayMode = twoUp ? .twoUpContinuous : .singlePageContinuous
        }
        pdfView.displaysAsBook = twoUp
        pdfView.backgroundColor = NSColor(hex: theme.background).blended(withFraction: theme.isDark ? 0.0 : 0.04, of: .black) ?? .windowBackgroundColor
        pdfView.isPaginated = p.layout == .paginated
        pdfView.autoScales = true
        applyDimming(p.dimPDFInDarkThemes && theme.isDark)
    }

    private func applyDimming(_ on: Bool) {
        pdfView.wantsLayer = true
        pdfView.layerUsesCoreImageFilters = true
        guard let layer = pdfView.documentView?.layer ?? pdfView.layer else { return }
        if on, let invert = CIFilter(name: "CIColorInvert"), let hue = CIFilter(name: "CIHueAdjust") {
            hue.setValue(Float.pi, forKey: kCIInputAngleKey)
            layer.filters = [invert, hue]
        } else {
            layer.filters = nil
        }
    }

    private var currentPageIndex: Int {
        guard let page = pdfView.currentPage, let document else { return 0 }
        return document.index(for: page)
    }

    private func pageChanged() {
        let count = max(1, document?.pageCount ?? 1)
        let index = currentPageIndex
        let visibleLast = pdfView.displayMode == .twoUp || pdfView.displayMode == .twoUpContinuous ? index + 1 : index
        model?.engineDidMove(to: Locator(index: index, progression: 0), page: index, pageCount: count, atEnd: visibleLast >= count - 1)
    }

    func willFollowLink() {
        guard !suppressJumpRecording else { return }
        model?.beginScrub()
    }

    // MARK: ReaderEngine

    func go(to locator: Locator, fragment: String?, atEnd: Bool) {
        guard let document, let page = document.page(at: min(max(0, locator.index), document.pageCount - 1)) else { return }
        suppressJumpRecording = true
        pdfView.go(to: page)
        suppressJumpRecording = false
    }

    func next() {
        suppressJumpRecording = true
        if pdfView.canGoToNextPage { pdfView.goToNextPage(nil) }
        suppressJumpRecording = false
    }

    func previous() {
        suppressJumpRecording = true
        if pdfView.canGoToPreviousPage { pdfView.goToPreviousPage(nil) }
        suppressJumpRecording = false
    }

    func refreshHighlights() {
        guard let document, let model else { return }
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            for a in page.annotations where a.userName?.hasPrefix(Self.highlightTag) == true { page.removeAnnotation(a) }
        }
        for h in model.state.liveHighlights {
            guard let rects = h.pdfRects, let page = document.page(at: h.locator.index) else { continue }
            for r in rects {
                let bounds = CGRect(x: r.x, y: r.y, width: r.width, height: r.height)
                let a = PDFAnnotation(bounds: bounds, forType: h.color == .underline ? .underline : .highlight, withProperties: nil)
                a.color = h.color.nsColor.withAlphaComponent(h.color == .underline ? 0.9 : 0.45)
                a.userName = "\(Self.highlightTag)|\(h.id.uuidString)"
                if let note = h.note, !note.isEmpty { a.contents = note }
                page.addAnnotation(a)
            }
        }
    }

    func reveal(_ result: SearchResult, query: String) {
        guard let document, let page = document.page(at: result.locator.index), let text = page.string else { return }
        let ns = text as NSString
        var range = NSRange(location: 0, length: ns.length)
        var found: NSRange?
        var n = 0
        while true {
            let r = ns.range(of: query, options: .caseInsensitive, range: range)
            if r.location == NSNotFound { break }
            if n == result.occurrence { found = r; break }
            n += 1
            range = NSRange(location: r.upperBound, length: ns.length - r.upperBound)
        }
        guard let found, let selection = page.selection(for: found) else { go(to: result.locator, fragment: nil, atEnd: false); return }
        suppressJumpRecording = true
        pdfView.go(to: selection)
        suppressJumpRecording = false
        selection.color = NSColor.systemYellow
        pdfView.highlightedSelections = [selection]
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.pdfView.highlightedSelections = nil }
    }

    func clearSelection() { pdfView.clearSelection() }

    func currentSectionText() async -> String {
        guard let document else { return "" }
        let current = currentPageIndex
        var start = max(0, current - 2), end = min(document.pageCount - 1, current + 2)
        if let entry = publication.tocEntry(forSpineIndex: current) {
            let starts = Self.flatten(publication.toc).map(\.spineIndex).sorted()
            let nextStart = starts.first { $0 > entry.spineIndex } ?? document.pageCount
            if nextStart - entry.spineIndex <= 40 {
                start = entry.spineIndex
                end = min(document.pageCount - 1, nextStart - 1)
            }
        }
        guard start <= end else { return "" }
        return (start...end).compactMap { i in document.page(at: i)?.string.map { "[Page \(i + 1)]\n\($0)" } }.joined(separator: "\n\n")
    }

    func currentSnippet() async -> String {
        let text = pdfView.currentPage?.string ?? ""
        return String(text.prefix(160)).collapsingWhitespace
    }

    private static func flatten(_ entries: [TOCEntry]) -> [TOCEntry] {
        entries.flatMap { [$0] + flatten($0.children) }
    }

    // MARK: Selection

    private func selectionChanged() {
        guard let model else { return }
        guard let sel = pdfView.currentSelection, let text = sel.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let page = sel.pages.first, let document else {
            if model.selection?.highlightID == nil { model.selection = nil }
            return
        }
        let lines = sel.selectionsByLine().filter { $0.pages.first == page }
        let rects = lines.map { $0.bounds(for: page) }.map { PDFRect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height) }
        let viewRect = flipped(pdfView.convert(sel.bounds(for: page), from: page))
        model.selection = ReaderSelection(text: text, rect: viewRect, pdfRects: rects, pageIndex: document.index(for: page))
    }

    private func flipped(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: pdfView.bounds.height - r.maxY, width: r.width, height: r.height)
    }

    func clickedAnnotation(_ annotation: PDFAnnotation, on page: PDFPage) -> Bool {
        guard let name = annotation.userName, name.hasPrefix(Self.highlightTag),
              let id = UUID(uuidString: String(name.split(separator: "|").last ?? "")),
              let model, let h = model.state.liveHighlights.first(where: { $0.id == id }) else { return false }
        let rect = flipped(pdfView.convert(annotation.bounds, from: page))
        model.selection = ReaderSelection(text: h.text, rect: rect, pdfRects: h.pdfRects, pageIndex: h.locator.index, highlightID: id)
        return true
    }

    var modelRef: ReaderModel? { model }
}

final class ReaderPDFView: PDFView {
    weak var engine: PDFEngine?
    var isPaginated = true
    private var accumulated = CGSize.zero
    private var gestureFired = false
    private var lastWheelTurn = Date.distantPast

    private var model: ReaderModel? { MainActor.assumeIsolated { engine?.modelRef } }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let model, isUnderOverlay(point, rects: model.overlayRects) { return nil }
        return super.hitTest(point)
    }

    override func go(to destination: PDFDestination) {
        MainActor.assumeIsolated { engine?.willFollowLink() }
        super.go(to: destination)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let model, JumpKeys.handle(event, model: model) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let page = page(for: point, nearest: false) {
            let pagePoint = convert(point, to: page)
            if let annotation = page.annotation(at: pagePoint),
               MainActor.assumeIsolated({ engine?.clickedAnnotation(annotation, on: page) }) == true {
                return
            }
        }
        super.mouseDown(with: event)
        // super runs the tracking loop; a plain click that selected nothing toggles the chrome.
        if event.clickCount == 1, currentSelection?.string?.isEmpty ?? true, let model {
            MainActor.assumeIsolated { model.toggleChrome() }
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let model, event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event); return
        }
        switch Int(event.keyCode) {
        case 123 where isPaginated: model.previousPage()
        case 124 where isPaginated: model.nextPage()
        case 125 where isPaginated, 121: model.nextPage()
        case 126 where isPaginated, 116: model.previousPage()
        case 49 where isPaginated: event.modifierFlags.contains(.shift) ? model.previousPage() : model.nextPage()
        case 53:
            if model.selection != nil { model.selection = nil; clearSelection() }
            else if model.showClaude || model.panel != nil { withAnimation(.spring(duration: 0.35)) { model.showClaude = false; model.panel = nil } }
            else { super.keyDown(with: event) }
        default: super.keyDown(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        // Zoomed in pages scroll normally; fitted pages turn on swipe.
        guard isPaginated, autoScales || scaleFactor <= scaleFactorForSizeToFit + 0.01, let model else {
            super.scrollWheel(with: event); return
        }
        if !event.momentumPhase.isEmpty { return }
        if event.phase.isEmpty {
            guard Date().timeIntervalSince(lastWheelTurn) > 0.28 else { return }
            let d = abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) ? event.scrollingDeltaY : event.scrollingDeltaX
            if d < 0 { model.nextPage() } else if d > 0 { model.previousPage() }
            lastWheelTurn = Date()
            return
        }
        if event.phase.contains(.began) { accumulated = .zero; gestureFired = false }
        accumulated.width += event.scrollingDeltaX
        accumulated.height += event.scrollingDeltaY
        guard !gestureFired else { return }
        if accumulated.width < -45 || accumulated.height < -70 { gestureFired = true; model.nextPage() }
        else if accumulated.width > 45 || accumulated.height > 70 { gestureFired = true; model.previousPage() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(where: { $0.userInfo?["reader"] != nil }) {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                           owner: self, userInfo: ["reader": true]))
        }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let y = convert(event.locationInWindow, from: nil).y
        if y > bounds.height - 90 || y < 90 { model?.pokeChrome() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard model?.selection != nil else { return menu }
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
        return menu
    }

    @objc private func menuAskClaude() { model?.askClaude(action: nil) }
    @objc private func menuHighlight() { model?.highlightSelection(.yellow) }
    @objc private func menuNote() { model?.addNoteToSelection() }
}
