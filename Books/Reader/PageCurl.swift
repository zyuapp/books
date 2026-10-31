import AppKit
import CoreImage
import IOSurface
import QuartzCore

/// A page-curl turn drawn over a reader view: snapshot the old page, turn underneath, then curl it away.
@MainActor
final class PageCurl {
    private var overlay: OverlayView?
    private(set) var generation = 0

    nonisolated private static let context = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: false])

    static var isEnabled: Bool {
        ReaderSettings.shared.prefs.pageTurnAnimation && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Starts a turn; any turn still running is dropped. Returns the turn's token.
    func begin() -> Int {
        generation += 1
        remove()
        return generation
    }

    func isCurrent(_ token: Int) -> Bool { token == generation }

    /// Stops the running curl where it is; the caller's turn has already happened underneath.
    func cancelAnimation() { generation += 1 }

    /// Freezes the current page on screen while the real turn happens underneath.
    func cover(_ host: NSView, with image: CGImage, paper: NSColor) {
        remove()
        let view = OverlayView(frame: host.bounds)
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        view.layer?.contentsGravity = .resize
        view.layer?.backgroundColor = paper.cgColor
        view.layer?.contents = image
        host.addSubview(view, positioned: .above, relativeTo: nil)
        overlay = view
    }

    /// Runs `body` with the overlay hidden, e.g. to snapshot what lies beneath it.
    func withoutOverlay<T>(_ body: () -> T) -> T {
        let hidden = overlay?.isHidden ?? true
        overlay?.isHidden = true
        defer { overlay?.isHidden = hidden }
        return body()
    }

    func remove() {
        overlay?.removeFromSuperview()
        overlay = nil
    }

    /// Curls `from` away to reveal `to` (forward), or curls `to` back over `from` (backward).
    func animate(from a: CGImage, to b: CGImage, forward: Bool, rightToLeft: Bool = false, paper: NSColor, token: Int,
                 duration: Double = 0.55) async {
        guard let overlay else { return }
        let paperImage = CIImage(color: CIColor(color: paper) ?? .white)
        // Snapshots of a transparent web view need the page colour behind them.
        func prepare(_ cg: CGImage) -> CIImage {
            let img = CIImage(cgImage: cg)
            return img.composited(over: paperImage).cropped(to: img.extent)
        }
        let imgA = prepare(a), imgB = prepare(b)
        let extent = imgA.extent
        // The page's back is the turning page mirrored, so the curled flap shows that page at full contrast.
        let pageForBack = forward ? imgA : imgB
        let backside = pageForBack.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -extent.width, y: 0))
        let radius = max(80, extent.width * 0.09)
        let pool = SurfacePool(width: Int(extent.width), height: Int(extent.height))

        let start = CACurrentMediaTime()
        while isCurrent(token) {
            let t = min(1, (CACurrentMediaTime() - start) / duration)
            let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            let time = forward ? eased : 1 - eased
            let input = forward ? imgA : imgB, target = forward ? imgB : imgA
            guard let surface = pool.next() else { return }
            let rendered = await Task.detached(priority: .userInitiated) {
                Self.render(input: input, target: target, backside: backside, extent: extent, time: time, radius: radius,
                            angle: rightToLeft ? -0.22 : Double.pi + 0.22, into: surface)
            }.value
            guard isCurrent(token) else { return }
            if rendered {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                overlay.layer?.contents = surface
                CATransaction.commit()
            }
            if t >= 1 { break }
        }
    }

    nonisolated private static func render(input: CIImage, target: CIImage, backside: CIImage, extent: CGRect,
                                           time: Double, radius: CGFloat, angle: Double, into surface: IOSurface) -> Bool {
        guard let filter = CIFilter(name: "CIPageCurlWithShadowTransition") else { return false }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(target, forKey: kCIInputTargetImageKey)
        filter.setValue(backside, forKey: "inputBacksideImage")
        filter.setValue(CIVector(cgRect: extent), forKey: kCIInputExtentKey)
        filter.setValue(time, forKey: kCIInputTimeKey)
        filter.setValue(angle, forKey: kCIInputAngleKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        filter.setValue(radius * 0.4, forKey: "inputShadowSize")
        filter.setValue(0.6, forKey: "inputShadowAmount")
        guard let output = filter.outputImage?.cropped(to: extent) else { return false }
        let destination = CIRenderDestination(ioSurface: surface)
        destination.colorSpace = sRGB
        return (try? context.startTask(toRender: output, to: destination).waitUntilCompleted()) != nil
    }

    nonisolated private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)

    /// Frame buffers at the snapshots' full pixel size, reusing ones the window server no longer shows.
    private final class SurfacePool {
        private let width: Int, height: Int
        private var surfaces: [IOSurface] = []

        init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }

        func next() -> IOSurface? {
            if let free = surfaces.first(where: { !$0.isInUse }) { return free }
            guard surfaces.count < 4, let surface = IOSurface(properties: [
                .width: width, .height: height, .bytesPerElement: 4, .pixelFormat: kCVPixelFormatType_32BGRA,
            ]) else { return surfaces.first }
            if let space = sRGB?.copyPropertyList() { surface.setAttachment(space, forKey: kIOSurfaceColorSpace as String) }
            surfaces.append(surface)
            return surface
        }
    }

    private final class OverlayView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
