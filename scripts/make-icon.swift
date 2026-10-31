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

    // Book glyph, drawn by hand: a closed book with page edges and a ribbon.
    let cream = NSColor(srgbRed: 1, green: 0.97, blue: 0.9, alpha: 1).cgColor
    let pageTint = NSColor(srgbRed: 0.93, green: 0.86, blue: 0.76, alpha: 1).cgColor
    let ribbon = NSColor(srgbRed: 0.62, green: 0.2, blue: 0.13, alpha: 1).cgColor
    let book = CGRect(x: rect.midX - 175 * s, y: rect.midY - 235 * s, width: 350 * s, height: 460 * s)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14 * s), blur: 30 * s,
                  color: NSColor(srgbRed: 0.3, green: 0.1, blue: 0.05, alpha: 0.55).cgColor)
    // Page block peeking out on the right and bottom.
    let pages = CGPath(roundedRect: book.offsetBy(dx: 18 * s, dy: -18 * s), cornerWidth: 34 * s, cornerHeight: 34 * s, transform: nil)
    ctx.addPath(pages); ctx.setFillColor(pageTint); ctx.fillPath()
    // Cover.
    let cover = CGPath(roundedRect: book, cornerWidth: 38 * s, cornerHeight: 38 * s, transform: nil)
    ctx.addPath(cover); ctx.setFillColor(cream); ctx.fillPath()
    ctx.restoreGState()
    // Page lines on the edge.
    ctx.setStrokeColor(NSColor(srgbRed: 0.78, green: 0.66, blue: 0.54, alpha: 1).cgColor)
    ctx.setLineWidth(3 * s)
    for i in 1...3 {
        let y = book.minY - CGFloat(i) * 4.5 * s
        ctx.move(to: CGPoint(x: book.minX + 40 * s, y: y)); ctx.addLine(to: CGPoint(x: book.maxX + 10 * s, y: y))
    }
    ctx.strokePath()
    // Spine groove.
    ctx.setFillColor(NSColor(srgbRed: 0.85, green: 0.76, blue: 0.64, alpha: 1).cgColor)
    ctx.fill(CGRect(x: book.minX + 58 * s, y: book.minY + 24 * s, width: 10 * s, height: book.height - 48 * s))
    // Title bars.
    ctx.setFillColor(NSColor(srgbRed: 0.78, green: 0.39, blue: 0.26, alpha: 0.85).cgColor)
    for (dy, w) in [(150.0, 170.0), (110.0, 120.0)] {
        let bar = CGRect(x: book.minX + 110 * s, y: book.maxY - CGFloat(dy) * s, width: CGFloat(w) * s, height: 22 * s)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 11 * s, cornerHeight: 11 * s, transform: nil)); ctx.fillPath()
    }
    // Ribbon.
    let rx = book.maxX - 90 * s
    ctx.beginPath()
    ctx.move(to: CGPoint(x: rx, y: book.maxY))
    ctx.addLine(to: CGPoint(x: rx + 46 * s, y: book.maxY))
    ctx.addLine(to: CGPoint(x: rx + 46 * s, y: book.maxY - 150 * s))
    ctx.addLine(to: CGPoint(x: rx + 23 * s, y: book.maxY - 126 * s))
    ctx.addLine(to: CGPoint(x: rx, y: book.maxY - 150 * s))
    ctx.closePath()
    ctx.setFillColor(ribbon); ctx.fillPath()

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
