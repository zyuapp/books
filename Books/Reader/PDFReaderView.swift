import AppKit
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

    private static let highlightTag = "com.zyu.books.highlight"

    init(model: ReaderModel, publication: Publication) {
        self.model = model
        self.publication = publication
        document = PDFDocument(url: publication.sourceURL)
        super.init()
        document?.delegate = self
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
        pdfView.postsFrameChangedNotifications = true
        observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fitPages() }
        })
        observers.append(center.addObserver(forName: .PDFViewScaleChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scaleChanged() }
        })
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
        paper = NSColor(hex: theme.background).blended(withFraction: theme.isDark ? 0.0 : 0.04, of: .black) ?? .windowBackgroundColor
        let layoutChanged = pdfView.isPaginated != (p.layout == .paginated) || lastDisplayMode != pdfView.displayMode
        lastDisplayMode = pdfView.displayMode
        pdfView.isPaginated = p.layout == .paginated
        fitPages(force: layoutChanged || (fittedScale == nil && !userZoomed))
        applyDimming(p.dimPDFInDarkThemes && theme.isDark)
        pdfView.backgroundColor = isDimmed ? paper.inverted : paper
        pdfView.pageShadowsEnabled = !isDimmed
        spreadImages = [:]
        prefetchNeighbors()
    }

    /// The color around the pages as the reader sees it.
    private var paper = NSColor.windowBackgroundColor
    private var isDimmed = false
    /// Inverts everything PDFKit shows, including the quick previews it draws without `DimmablePDFPage`.
    private let invertOverlay: NSView = {
        let view = PassthroughView()
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        view.layer?.backgroundColor = .white
        view.layer?.compositingFilter = "differenceBlendMode"
        return view
    }()

    private func applyDimming(_ on: Bool) {
        guard on != isDimmed, let document else { return }
        isDimmed = on
        for i in 0..<document.pageCount { (document.page(at: i) as? DimmablePDFPage)?.isDimmed = on }
        guard pdfView.document != nil else { return }
        // PDFKit keeps rendered tiles until the document is reattached.
        let destination = pdfView.currentDestination
        let autoScales = pdfView.autoScales, scale = pdfView.scaleFactor
        suppressJumpRecording = true
        pdfView.document = nil
        pdfView.document = document
        if autoScales { pdfView.autoScales = true } else { pdfView.scaleFactor = scale }
        if let destination { pdfView.go(to: destination) }
        suppressJumpRecording = false
        if on {
            invertOverlay.frame = pdfView.bounds
            pdfView.addSubview(invertOverlay, positioned: .above, relativeTo: nil)
        } else {
            invertOverlay.removeFromSuperview()
        }
    }

    /// Paged mode shows whole pages (fit to window, below the toolbar); scroll mode fits the width.
    private var fittedScale: CGFloat?
    private var lastDisplayMode: PDFDisplayMode?

    private var userZoomed = false

    func zoom(by step: Int) {
        guard step != 0 else { return fitPages(force: true) }
        userZoomed = true
        pdfView.autoScales = false
        pdfView.scaleFactor = min(6, max(0.25, pdfView.scaleFactor * pow(1.15, CGFloat(step))))
    }

    func scrollContent(by fraction: CGFloat) {
        guard pdfView.isPaginated, let clip = pdfView.documentView?.enclosingScrollView?.contentView else { return }
        pan(dx: 0, dy: clip.bounds.height * fraction)
    }

    /// Moves the view over the current page(s) without letting PDFKit flip to another page at the edges.
    /// Positive `dy` moves toward the bottom of the page.
    func pan(dx: CGFloat, dy: CGFloat) {
        guard let doc = pdfView.documentView, let scrollView = doc.enclosingScrollView else { return }
        let clip = scrollView.contentView
        let frame = doc.frame, size = clip.bounds.size
        var origin = clip.bounds.origin
        if frame.width > size.width {
            origin.x = min(max(origin.x + dx, frame.minX), frame.maxX - size.width)
        }
        if frame.height > size.height {
            origin.y = min(max(origin.y + (clip.isFlipped ? dy : -dy), frame.minY), frame.maxY - size.height)
        }
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }

    private func scaleChanged() {
        model?.zoomPercent = userZoomed ? Int((pdfView.scaleFactor * 100).rounded()) : nil
    }

    /// Refits unless the user has zoomed away from the last fit (pass `force` after a layout change).
    private func fitPages(force: Bool = false) {
        if !force, userZoomed { return }
        if !force, let fitted = fittedScale, abs(pdfView.scaleFactor - fitted) > 0.01 { return }
        if userZoomed {
            userZoomed = false
            model?.zoomPercent = nil
        }
        guard pdfView.isPaginated, let page = pdfView.currentPage ?? document?.page(at: 0) else {
            pdfView.autoScales = true
            return
        }
        let size = page.bounds(for: pdfView.displayBox).size
        guard size.width > 0, size.height > 0, pdfView.bounds.width > 0 else { return }
        let columns: CGFloat = pdfView.displayMode == .twoUp ? 2 : 1
        let availableW = pdfView.bounds.width - 60
        let availableH = pdfView.bounds.height - 130
        pdfView.autoScales = false
        pdfView.scaleFactor = max(0.1, min(availableW / (size.width * columns), availableH / size.height))
        fittedScale = pdfView.scaleFactor
    }

    private var currentPageIndex: Int {
        guard let page = pdfView.currentPage, let document else { return 0 }
        return document.index(for: page)
    }

    private func pageChanged() {
        prefetchNeighbors()
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

    func next() { turn(forward: true) }
    func previous() { turn(forward: false) }

    private let curl = PageCurl()

    func focusContent() { pdfView.window?.makeFirstResponder(pdfView) }

    func locate(_ quote: String) async -> HighlightTarget? {
        guard let document else { return nil }
        let words = quote.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let start = currentPageIndex
        // Prefer the visible page, then search outward through the document.
        let order = [start] + (0..<document.pageCount).filter { $0 != start }
        for i in order {
            guard let page = document.page(at: i), let text = page.string else { continue }
            let normalized = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            guard normalized.range(of: words, options: [.caseInsensitive, .diacriticInsensitive]) != nil,
                  let selection = document.findString(words, withOptions: [.caseInsensitive]).first(where: { $0.pages.first == page })
                    ?? page.selection(for: (text as NSString).range(of: quote, options: .caseInsensitive))
            else { continue }
            let rects = selection.selectionsByLine().compactMap { line -> PDFRect? in
                guard line.pages.first == page else { return nil }
                let b = line.bounds(for: page)
                return PDFRect(x: b.minX, y: b.minY, width: b.width, height: b.height)
            }
            guard !rects.isEmpty else { continue }
            return HighlightTarget(text: selection.string ?? quote, index: i, progression: 0, pdfRects: rects)
        }
        return nil
    }

    private func turn(forward: Bool) {
        guard forward ? pdfView.canGoToNextPage : pdfView.canGoToPreviousPage else { return }
        let step = {
            self.suppressJumpRecording = true
            forward ? self.pdfView.goToNextPage(nil) : self.pdfView.goToPreviousPage(nil)
            self.suppressJumpRecording = false
        }
        if PageCurl.isEnabled, pdfView.isPaginated, !userZoomed,
           let current = spread(0), let target = spread(forward ? 1 : -1),
           let before = spreadImages[spreadKey(current)], let after = spreadImages[spreadKey(target)] {
            let token = curl.begin()
            let paper = self.paper
            curl.cover(pdfView, with: before, paper: paper)
            step()
            Task {
                await curl.animate(from: before, to: after, forward: forward, paper: paper, token: token)
                if curl.isCurrent(token) { curl.remove() }
            }
            return
        }
        guard PageCurl.isEnabled, pdfView.isPaginated, let before = snapshot() else {
            _ = curl.begin()
            step()
            return
        }
        let token = curl.begin()
        let paper = self.paper
        curl.cover(pdfView, with: before, paper: paper)
        step()
        Task {
            try? await Task.sleep(for: .milliseconds(30))
            guard curl.isCurrent(token), let after = snapshot() else {
                if curl.isCurrent(token) { curl.remove() }
                return
            }
            await curl.animate(from: before, to: after, forward: forward, paper: paper, token: token)
            if curl.isCurrent(token) { curl.remove() }
        }
    }

    /// Renders the visible pages as they sit in the view (PDFKit's layers don't show up in cacheDisplay).
    private func snapshot() -> CGImage? {
        let bounds = pdfView.bounds
        let scale = pdfView.window?.backingScaleFactor ?? 2
        guard bounds.width > 0, document != nil else { return nil }
        let pixelsPerUnit = scale * pdfView.scaleFactor
        let pages = pdfView.visiblePages.compactMap { page -> (CGRect, CGImage)? in
            let rect = displayedFrame(of: page)
            guard rect.intersects(bounds), let image = pageImage(page, pixelsPerUnit: pixelsPerUnit) else { return nil }
            return (rect, image)
        }
        return Self.compose(size: bounds.size, scale: scale, background: pdfView.backgroundColor.cgColor, dimmed: isDimmed, pages: pages)
    }

    nonisolated private static func compose(size: CGSize, scale: CGFloat, background: CGColor, dimmed: Bool,
                                            pages: [(CGRect, CGImage)]) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let all = CGRect(origin: .zero, size: size)
        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(background)
        ctx.fill(all)
        for (rect, image) in pages {
            ctx.saveGState()
            if !dimmed { ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 8, color: CGColor(gray: 0, alpha: 0.3)) }
            ctx.setFillColor(.white)
            ctx.fill(rect)
            ctx.restoreGState()
            let drawn = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
            ctx.saveGState()
            ctx.clip(to: rect)
            ctx.draw(image, in: CGRect(origin: CGPoint(x: rect.minX, y: rect.maxY - drawn.height), size: drawn))
            ctx.restoreGState()
        }
        if dimmed {
            ctx.setBlendMode(.difference)
            ctx.setFillColor(.white)
            ctx.fill(all)
        }
        return ctx.makeImage()
    }

    /// Where PDFKit actually draws the page: its page view's frame, which can sit half a point off `convert(_:from:)`.
    private func displayedFrame(of page: PDFPage) -> CGRect {
        let estimate = pdfView.convert(page.bounds(for: pdfView.displayBox), from: page)
        let frames = pdfView.documentView?.subviews.map { $0.convert($0.bounds, to: pdfView) } ?? []
        return frames.first {
            abs($0.midX - estimate.midX) < 2 && abs($0.midY - estimate.midY) < 2
                && abs($0.width - estimate.width) < 2 && abs($0.height - estimate.height) < 2
        } ?? estimate
    }

    /// Draws a page's vectors at PDFKit's own tile resolution, so every glyph lands on the pixel it has on screen.
    /// The bitmap is rounded up to whole pixels at the top; the page's bottom-left sits at pixel (0, 0).
    nonisolated private static func render(_ page: PDFPage, box displayBox: PDFDisplayBox, pixelsPerUnit: CGFloat) -> CGImage? {
        let box = page.bounds(for: displayBox)
        let quarterTurned = page.rotation % 180 != 0
        let natural = quarterTurned ? CGSize(width: box.height, height: box.width) : box.size
        let exactHeight = natural.height * pixelsPerUnit
        let pixelsWide = Int((natural.width * pixelsPerUnit).rounded(.up)), pixelsHigh = Int(exactHeight.rounded(.up))
        guard pixelsWide > 0, pixelsHigh > 0,
              let ctx = CGContext(data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
        ctx.translateBy(x: 0, y: CGFloat(pixelsHigh) - exactHeight)
        ctx.scaleBy(x: pixelsPerUnit, y: pixelsPerUnit)
        page.draw(with: displayBox, to: ctx)
        return ctx.makeImage()
    }

    /// Page bitmaps for the curl by page index, rendered ahead for the neighbouring spreads so a turn starts at once.
    private var pageImages: [Int: CGImage] = [:]
    /// Whole-view snapshots of the current and neighbouring spreads, keyed by `spreadKey`.
    private var spreadImages: [String: CGImage] = [:]
    private var pageImagesKey = ""
    private var prefetchTask: Task<Void, Never>?

    private func syncPageImages(pixelsPerUnit: CGFloat) {
        let key = "\(pixelsPerUnit)|\(isDimmed)|\(pdfView.displayBox.rawValue)"
        guard key != pageImagesKey else { return }
        prefetchTask?.cancel()
        pageImages = [:]
        spreadImages = [:]
        pageImagesKey = key
    }

    /// The spread `offset` spreads from the visible one, placed in the visible pages' frames,
    /// or nil when its pages wouldn't sit in those frames (cover page, last page, mixed page sizes).
    private func spread(_ offset: Int) -> [(index: Int, rect: CGRect)]? {
        guard let document else { return nil }
        let box = pdfView.displayBox
        let visible = pdfView.visiblePages
            .map { (index: document.index(for: $0), rect: displayedFrame(of: $0), size: $0.bounds(for: box).size) }
            .sorted { $0.index < $1.index }
        guard let first = visible.first, let last = visible.last else { return nil }
        if offset != 0, pdfView.displayMode == .twoUp, visible.count == 1 { return nil }
        let start = offset == 0 ? first.index : offset > 0 ? last.index + 1 : first.index - visible.count
        guard start >= 0, start + visible.count <= document.pageCount else { return nil }
        var out: [(index: Int, rect: CGRect)] = []
        for (k, slot) in visible.enumerated() {
            guard let size = document.page(at: start + k)?.bounds(for: box).size,
                  abs(size.width - slot.size.width) < 1, abs(size.height - slot.size.height) < 1 else { return nil }
            out.append((start + k, slot.rect))
        }
        return out
    }

    private func spreadKey(_ spread: [(index: Int, rect: CGRect)]) -> String {
        "\(pdfView.bounds.size)|" + spread.map { "\($0.index)@\($0.rect)" }.joined(separator: ",")
    }

    private func pageImage(_ page: PDFPage, pixelsPerUnit: CGFloat) -> CGImage? {
        guard let document else { return nil }
        syncPageImages(pixelsPerUnit: pixelsPerUnit)
        let index = document.index(for: page)
        if let image = pageImages[index] { return image }
        let image = Self.render(page, box: pdfView.displayBox, pixelsPerUnit: pixelsPerUnit)
        pageImages[index] = image
        return image
    }

    private func prefetchNeighbors() {
        guard PageCurl.isEnabled, pdfView.isPaginated, let document, document.pageCount > 0 else { return }
        let pixelsPerUnit = (pdfView.window?.backingScaleFactor ?? 2) * pdfView.scaleFactor
        syncPageImages(pixelsPerUnit: pixelsPerUnit)
        let current = currentPageIndex
        let wanted = max(0, current - 2)...min(document.pageCount - 1, current + 3)
        pageImages = pageImages.filter { wanted.contains($0.key) }
        let missing = wanted.filter { pageImages[$0] == nil }.sorted { abs($0 - current) < abs($1 - current) }
            .compactMap { i in (document.page(at: i) as? DimmablePDFPage).map { (i, $0) } }
        let key = pageImagesKey, box = pdfView.displayBox
        let size = pdfView.bounds.size, scale = pdfView.window?.backingScaleFactor ?? 2
        let background = pdfView.backgroundColor.cgColor, dimmed = isDimmed
        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
            // Leave the running curl the CPU first.
            try? await Task.sleep(for: .milliseconds(250))
            for (index, page) in missing {
                guard !Task.isCancelled else { return }
                let image = await Task.detached(priority: .utility) {
                    Self.render(page, box: box, pixelsPerUnit: pixelsPerUnit)
                }.value
                guard let self, self.pageImagesKey == key else { return }
                self.pageImages[index] = image
            }
            guard !Task.isCancelled, let self, self.pageImagesKey == key, !self.userZoomed else { return }
            let spreads = [0, 1, -1].compactMap { offset in self.spread(offset).map { (key: self.spreadKey($0), layout: $0) } }
            self.spreadImages = self.spreadImages.filter { entry in spreads.contains { $0.key == entry.key } }
            for spread in spreads where self.spreadImages[spread.key] == nil {
                guard !Task.isCancelled, self.pageImagesKey == key else { return }
                let pages = spread.layout.compactMap { item in self.pageImages[item.index].map { (item.rect, $0) } }
                guard pages.count == spread.layout.count else { continue }
                let image = await Task.detached(priority: .utility) {
                    Self.compose(size: size, scale: scale, background: background, dimmed: dimmed, pages: pages)
                }.value
                guard self.pageImagesKey == key else { return }
                self.spreadImages[spread.key] = image
            }
        }
    }

    func refreshHighlights() {
        pageImagesKey = ""
        spreadImages = [:]
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

    func currentPageText() async -> String {
        guard let document else { return "" }
        return pdfView.visiblePages.compactMap { page in
            page.string.map { "[Page \(document.index(for: page) + 1)]\n\($0)" }
        }.joined(separator: "\n\n")
    }

    func currentSnippet() async -> String {
        let text = pdfView.currentPage?.string ?? ""
        return String(text.prefix(160)).collapsingWhitespace
    }

    private static func flatten(_ entries: [TOCEntry]) -> [TOCEntry] {
        entries.flatMap { [$0] + flatten($0.children) }
    }

    // MARK: Selection

    func selectionChanged() {
        guard let model, !pdfView.isTrackingMouse else { return }
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

extension PDFEngine: PDFDocumentDelegate {
    nonisolated func classForPage() -> AnyClass { DimmablePDFPage.self }
}

/// Draws the inverse of the dark page in the page's own context, so text stays as sharp as the light page;
/// the engine's difference overlay turns it back into the dark page.
nonisolated final class DimmablePDFPage: PDFPage, @unchecked Sendable {
    var isDimmed = false

    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        guard isDimmed else { return super.draw(with: box, to: context) }
        let rect = bounds(for: box)
        context.saveGState()
        context.setFillColor(.white)
        context.fill(rect)
        super.draw(with: box, to: context)
        // Keeps each color's hue and saturation and inverts its lightness.
        context.setBlendMode(.luminosity)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setBlendMode(.normal)
        context.setFillColor(.white)
        context.fill(rect)
        super.draw(with: box, to: context)
        context.setBlendMode(.difference)
        context.fill(rect)
        context.endTransparencyLayer()
        context.setBlendMode(.difference)
        context.setFillColor(.white)
        context.fill(rect)
        context.restoreGState()
    }
}

final class ReaderPDFView: PDFView {
    weak var engine: PDFEngine?
    var isPaginated = true
    private(set) var isTrackingMouse = false

    private var model: ReaderModel? { MainActor.assumeIsolated { engine?.modelRef } }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let model, isUnderOverlay(point, rects: model.overlayRects) { return nil }
        return super.hitTest(point)
    }

    override func go(to destination: PDFDestination) {
        MainActor.assumeIsolated { engine?.willFollowLink() }
        super.go(to: destination)
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
        isTrackingMouse = true
        super.mouseDown(with: event)
        isTrackingMouse = false
        MainActor.assumeIsolated { engine?.selectionChanged() }
        // super runs the tracking loop; a plain click that selected nothing toggles the chrome.
        if event.clickCount == 1, currentSelection?.string?.isEmpty ?? true, let model {
            MainActor.assumeIsolated { model.toggleChrome() }
        }
    }

    private var wheelMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor); self.wheelMonitor = nil }
        guard window != nil else { return }
        // PDFKit's inner scroll view takes wheel events (and flips pages with them) before this view sees them.
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            guard let self, event.window === self.window, self.isPaginated, let superview = self.superview else { return event }
            let p = superview.convert(event.locationInWindow, from: nil)
            guard self.frame.contains(p), !self.isUnderOverlay(p, rects: self.model?.overlayRects ?? []) else { return event }
            // Paged mode never turns pages from the wheel or trackpad; it only pans a zoomed-in page.
            let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            MainActor.assumeIsolated { self.engine?.pan(dx: -event.scrollingDeltaX * k, dy: -event.scrollingDeltaY * k) }
            return nil
        }
    }

    override func removeFromSuperview() {
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor); self.wheelMonitor = nil }
        super.removeFromSuperview()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(where: { $0.userInfo?["reader"] != nil }) {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                           owner: self, userInfo: ["reader": true]))
        }
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

private final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private extension NSColor {
    var inverted: NSColor {
        guard let c = usingColorSpace(.sRGB) else { return self }
        return NSColor(srgbRed: 1 - c.redComponent, green: 1 - c.greenComponent, blue: 1 - c.blueComponent, alpha: c.alphaComponent)
    }
}
