// Renders the app icon, an owl reading an open book, into PageOwl/Resources/Assets.xcassets/AppIcon.appiconset.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha).cgColor
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    // Draw in a 1024-point canvas, y up.
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    let space = CGColorSpaceCreateDeviceRGB()

    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    func fill(_ path: CGPath, _ color: CGColor) {
        ctx.addPath(path); ctx.setFillColor(color); ctx.fillPath()
    }
    func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h), transform: nil)
    }
    func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> CGPath { ellipse(cx, cy, 2 * r, 2 * r) }

    // Tile: night-blue gradient with a drop shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    fill(tilePath, rgb(0x1F2A4D))
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let bg = CGGradient(colorsSpace: space, colors: [rgb(0x3B5087), rgb(0x24305A), rgb(0x161D38)] as CFArray,
                        locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])

    // Warm reading-lamp glow behind the owl.
    let glow = CGGradient(colorsSpace: space, colors: [rgb(0xFFD58A, 0.38), rgb(0xFFD58A, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 560), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 560), endRadius: 400, options: [])

    // Owl, drawn behind the book so it peeks over the pages.
    let brown = rgb(0x8A5A3B), dark = rgb(0x6B4129), belly = rgb(0xD9A66B), face = rgb(0xF0CF98)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x0B1026, 0.5))
    // Ear tufts and body share one silhouette.
    let owl = CGMutablePath()
    owl.addEllipse(in: CGRect(x: 322, y: 330, width: 380, height: 430))
    owl.move(to: CGPoint(x: 360, y: 680)); owl.addLine(to: CGPoint(x: 352, y: 785)); owl.addLine(to: CGPoint(x: 452, y: 735)); owl.closeSubpath()
    owl.move(to: CGPoint(x: 664, y: 680)); owl.addLine(to: CGPoint(x: 672, y: 785)); owl.addLine(to: CGPoint(x: 572, y: 735)); owl.closeSubpath()
    fill(owl, brown)
    ctx.restoreGState()
    // Wings.
    for side: CGFloat in [-1, 1] {
        ctx.saveGState()
        ctx.translateBy(x: 512 + side * 168, y: 500)
        ctx.rotate(by: side * 0.18)
        fill(ellipse(0, 0, 120, 270), dark)
        ctx.restoreGState()
    }
    fill(ellipse(512, 500, 230, 250), belly)
    // Belly feathers.
    ctx.setStrokeColor(rgb(0xB9864F)); ctx.setLineWidth(9); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    for (x, y) in [(470.0, 520.0), (554.0, 520.0), (512.0, 470.0)] {
        ctx.move(to: CGPoint(x: x - 22, y: y + 14)); ctx.addLine(to: CGPoint(x: x, y: y)); ctx.addLine(to: CGPoint(x: x + 22, y: y + 14))
    }
    ctx.strokePath()
    // Face: two discs, big eyes looking down at the book.
    for x: CGFloat in [432, 592] {
        fill(circle(x, 640, 102), face)
        fill(circle(x, 640, 76), rgb(0xFFFFFF))
        fill(circle(x + (x < 512 ? 8 : -8), 618, 42), rgb(0x1B1A2A))
        fill(circle(x + (x < 512 ? 22 : 6), 636, 13), rgb(0xFFFFFF))
    }
    let beak = CGMutablePath()
    beak.move(to: CGPoint(x: 486, y: 600)); beak.addLine(to: CGPoint(x: 538, y: 600)); beak.addLine(to: CGPoint(x: 512, y: 548)); beak.closeSubpath()
    fill(beak, rgb(0xF2A33A))

    // Open book in front: a cover underneath, then two curved pages meeting at the spine.
    func page(_ side: CGFloat, inset: CGFloat = 0) -> CGPath {
        let p = CGMutablePath()
        let outer = 512 + side * (262 - inset)
        p.move(to: CGPoint(x: 512, y: 250))
        p.addQuadCurve(to: CGPoint(x: outer, y: 292), control: CGPoint(x: 512 + side * 120, y: 300))
        p.addLine(to: CGPoint(x: outer, y: 452))
        p.addQuadCurve(to: CGPoint(x: 512, y: 418), control: CGPoint(x: 512 + side * 120, y: 470))
        p.closeSubpath()
        return p
    }
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 26, color: rgb(0x0B1026, 0.55))
    for side: CGFloat in [-1, 1] {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: -24)
        ctx.translateBy(x: 512, y: 0); ctx.scaleBy(x: 1.05, y: 1); ctx.translateBy(x: -512, y: 0)
        fill(page(side), rgb(0xC8553D))
        ctx.restoreGState()
    }
    ctx.restoreGState()
    for side: CGFloat in [-1, 1] {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: -12)
        fill(page(side), rgb(0xE9DCC3))
        ctx.restoreGState()
        fill(page(side), rgb(0xFFF7E8))
        // Shade toward the spine.
        ctx.saveGState()
        ctx.addPath(page(side)); ctx.clip()
        let shade = CGGradient(colorsSpace: space, colors: [rgb(0xC9B48F, 0.55), rgb(0xC9B48F, 0)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(shade, start: CGPoint(x: 512, y: 0), end: CGPoint(x: 512 + side * 90, y: 0), options: [])
        ctx.restoreGState()
        // Text lines.
        ctx.setStrokeColor(rgb(0xD6C3A0)); ctx.setLineWidth(10); ctx.setLineCap(.round)
        for i in 0..<3 {
            let y = 330 + CGFloat(i) * 32
            ctx.move(to: CGPoint(x: 512 + side * 60, y: y + 12))
            ctx.addQuadCurve(to: CGPoint(x: 512 + side * 210, y: y + 24), control: CGPoint(x: 512 + side * 135, y: y + 30))
        }
        ctx.strokePath()
    }
    ctx.setStrokeColor(rgb(0xB89C70)); ctx.setLineWidth(5)
    ctx.move(to: CGPoint(x: 512, y: 252)); ctx.addLine(to: CGPoint(x: 512, y: 416)); ctx.strokePath()

    // Wing tips holding the pages.
    for side: CGFloat in [-1, 1] {
        ctx.saveGState()
        ctx.translateBy(x: 512 + side * 150, y: 440)
        ctx.rotate(by: side * -0.5)
        fill(ellipse(0, 0, 64, 104), dark)
        ctx.restoreGState()
    }

    // Glass sheen across the top and a hairline rim.
    let sheen = CGGradient(colorsSpace: space, colors: [NSColor(white: 1, alpha: 0.22).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: tile.maxY), end: CGPoint(x: 512, y: 620), options: [])
    ctx.restoreGState()

    ctx.addPath(tilePath)
    ctx.setStrokeColor(NSColor(white: 1, alpha: 0.3).cgColor)
    ctx.setLineWidth(3)
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
