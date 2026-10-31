// Renders the app icon into Books/Resources/Assets.xcassets/AppIcon.appiconset.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])

func render(_ px: Int) -> Data {
    let size = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size / 1024
    let rect = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = CGPath(roundedRect: rect, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)

    // Shadow + base gradient.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(path)
    ctx.setFillColor(NSColor(srgbRed: 0.78, green: 0.39, blue: 0.26, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let colors = [NSColor(srgbRed: 0.93, green: 0.55, blue: 0.38, alpha: 1).cgColor,
                  NSColor(srgbRed: 0.72, green: 0.33, blue: 0.21, alpha: 1).cgColor,
                  NSColor(srgbRed: 0.45, green: 0.19, blue: 0.12, alpha: 1).cgColor] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])

    // Soft glow behind the book.
    let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [NSColor(white: 1, alpha: 0.28).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: rect.midX, y: rect.midY + 40 * s), startRadius: 0,
                           endCenter: CGPoint(x: rect.midX, y: rect.midY + 40 * s), endRadius: 420 * s, options: [])

    // Book glyph.
    let config = NSImage.SymbolConfiguration(pointSize: 440 * s, weight: .medium)
        .applying(.init(paletteColors: [NSColor(srgbRed: 1, green: 0.97, blue: 0.9, alpha: 1)]))
    if let symbol = NSImage(systemSymbolName: "text.book.closed.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let sz = symbol.size
        let r = CGRect(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2 - 10 * s, width: sz.width, height: sz.height)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -14 * s), blur: 30 * s, color: NSColor(srgbRed: 0.3, green: 0.1, blue: 0.05, alpha: 0.55).cgColor)
        symbol.draw(in: r)
        ctx.restoreGState()
    }

    // Glass sheen across the top half and a hairline rim.
    let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [NSColor(white: 1, alpha: 0.38).cgColor, NSColor(white: 1, alpha: 0.0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.midY + 60 * s), options: [])
    ctx.restoreGState()

    ctx.addPath(path)
    ctx.setStrokeColor(NSColor(white: 1, alpha: 0.35).cgColor)
    ctx.setLineWidth(3 * s)
    ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try! render(px).write(to: out.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(base)x\(base)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted]).write(to: out.appendingPathComponent("Contents.json"))
