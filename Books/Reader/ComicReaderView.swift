import AppKit
import Observation
import SwiftUI

/// Comic archives: one page (or a two-page spread) fitted to the window.
@MainActor @Observable
final class ComicEngine: ReaderEngine {
    let publication: Publication
    private weak var model: ReaderModel?
    private(set) var index = 0
    var spread = false
    var rightToLeft: Bool

    @ObservationIgnored private var cache: [Int: NSImage] = [:]

    init(model: ReaderModel, publication: Publication) {
        self.model = model
        self.publication = publication
        rightToLeft = ReaderSettings.shared.prefs.comicRightToLeft ?? publication.rightToLeft
        index = min(model.restoreTarget().index, publication.spine.count - 1)
    }

    var visiblePages: [Int] {
        guard spread, index > 0 else { return [index] }
        let start = index % 2 == 1 ? index : index - 1
        return [start, start + 1].filter { $0 < publication.spine.count }
    }

    func image(_ i: Int) -> NSImage? {
        if let img = cache[i] { return img }
        guard publication.spine.indices.contains(i), let img = NSImage(contentsOf: publication.spine[i].url) else { return nil }
        if cache.count > 12 { cache.removeAll() }
        cache[i] = img
        return img
    }

    private func preload() {
        let ahead = (index + 1)...min(publication.spine.count - 1, index + 3)
        let urls = ahead.isEmpty ? [] : ahead.map { publication.spine[$0].url }
        Task.detached(priority: .utility) { for u in urls { _ = NSImage(contentsOf: u)?.cgImage(forProposedRect: nil, context: nil, hints: nil) } }
    }

    private func moved() {
        let last = visiblePages.last ?? index
        model?.engineDidMove(to: Locator(index: index), page: last, pageCount: publication.spine.count,
                             atEnd: last >= publication.spine.count - 1)
        preload()
    }

    func go(to locator: Locator, fragment: String?, atEnd: Bool) {
        index = min(max(0, locator.index), publication.spine.count - 1)
        moved()
    }

    func next() {
        let step = spread && index > 0 ? visiblePages.count : 1
        let base = spread && index > 0 ? visiblePages.first! : index
        guard base + step < publication.spine.count else { return }
        withAnimation(.easeInOut(duration: 0.18)) { index = base + step }
        moved()
    }

    func previous() {
        guard index > 0 else { return }
        let base = spread ? visiblePages.first! : index
        withAnimation(.easeInOut(duration: 0.18)) { index = max(0, base - (spread && base > 1 ? 2 : 1)) }
        moved()
    }

    func applySettings() {}
    func refreshHighlights() {}
    func reveal(_ result: SearchResult, query: String) { go(to: result.locator, fragment: nil, atEnd: false) }
    func clearSelection() {}
    func currentSectionText() async -> String { "" }
    func currentPageText() async -> String { "" }
    func currentSnippet() async -> String { "Page \(index + 1)" }
    func start() { moved() }
    func focusContent() { NSApp.keyWindow?.makeFirstResponder(nil) }
}

struct ComicReaderView: View {
    let model: ReaderModel
    @State private var engine: ComicEngine
    let prefs: ReaderPreferences

    init(model: ReaderModel, publication: Publication, prefs: ReaderPreferences) {
        self.model = model
        self.prefs = prefs
        _engine = State(initialValue: ComicEngine(model: model, publication: publication))
    }

    var body: some View {
        GeometryReader { geo in
            let spread = prefs.spread == .double || (prefs.spread == .auto && geo.size.width > geo.size.height * 1.15)
            let pages = engine.rightToLeft ? engine.visiblePages.reversed() : engine.visiblePages
            HStack(spacing: 0) {
                ForEach(pages, id: \.self) { i in
                    if let img = engine.image(i) {
                        Image(nsImage: img)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
                    }
                }
            }
            .padding(.vertical, 28)
            .frame(width: geo.size.width, height: geo.size.height)
            .id(engine.visiblePages.first)
            .transition(.opacity)
            .overlay(EventCatcher(
                overlayRects: { model.overlayRects },
                rightToLeft: { engine.rightToLeft },
                onClick: { fractionX in
                    if model.dismissPanel() { return }
                    if fractionX > 0.35 && fractionX < 0.65 { model.pokeChrome(); return }
                    (fractionX < 0.5) != engine.rightToLeft ? model.previousPage() : model.nextPage()
                }
            ))
            .onAppear {
                engine.spread = spread
                model.engine = engine
                engine.start()
            }
            .onChange(of: spread) { _, s in engine.spread = s }
        }
    }
}

/// Captures clicks and mouse movement for SwiftUI-rendered readers, and swallows wheel scrolling.
struct EventCatcher: NSViewRepresentable {
    var overlayRects: () -> [CGRect] = { [] }
    var rightToLeft: () -> Bool = { false }
    var onClick: ((CGFloat) -> Void)? = nil

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.handlers = self
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        return v
    }

    func updateNSView(_ view: CatcherView, context: Context) { view.handlers = self }

    final class CatcherView: NSView {
        var handlers: EventCatcher?

        override var acceptsFirstResponder: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            if let rects = handlers?.overlayRects(), isUnderOverlay(point, rects: rects) { return nil }
            return super.hitTest(point)
        }

        override func scrollWheel(with event: NSEvent) {}

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if trackingAreas.isEmpty {
                addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
            }
        }


        override func mouseUp(with event: NSEvent) {
            window?.makeFirstResponder(self)
            guard let onClick = handlers?.onClick, bounds.width > 0 else { return }
            onClick(convert(event.locationInWindow, from: nil).x / bounds.width)
        }

        override func mouseDown(with event: NSEvent) {}
    }
}
