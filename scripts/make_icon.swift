// Draws the Neutrino app icon at 1024×1024 and writes it as a PNG.
// Usage: swift scripts/make_icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "icon_1024.png"

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func withShadow(_ shadowColor: NSColor, blur: CGFloat, y: CGFloat, _ draw: () -> Void) {
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.saveGState()
    let shadow = NSShadow()
    shadow.shadowColor = shadowColor
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = NSSize(width: 0, height: y)
    shadow.set()
    draw()
    ctx.restoreGState()
}

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Background squircle (Apple icon grid: 824pt body, 100pt margin), dark gradient.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
withShadow(color(0x000000, 0.3), blur: 28, y: -12) {
    color(0x14162B).setFill()
    squircle.fill()
}
ctx.saveGState()
squircle.addClip()
NSGradient(colors: [color(0x343A6B), color(0x14162B)])!.draw(in: body, angle: -90)

// Lines of code, as coloured bars.
let rows: [[(CGFloat, UInt32)]] = [
    [(150, 0xFF7AB2), (230, 0x6BDFFF)],
    [(90, 0xB281EB), (170, 0xFFFFFF), (120, 0xFF8170)],
    [(210, 0xFFFFFF), (110, 0xD9C97C)],
    [(120, 0xFF7AB2), (260, 0x7F8C98)],
    [(180, 0x6BDFFF)],
]
let lineHeight: CGFloat = 44
for (i, row) in rows.enumerated() {
    var x = body.minX + 130 + (i == 1 || i == 2 ? 70 : 0)
    let y = 700 - CGFloat(i) * 92
    for (width, hex) in row {
        color(hex, i == 3 ? 0.9 : 1).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: x, y: y, width: width, height: lineHeight),
            xRadius: lineHeight / 2, yRadius: lineHeight / 2
        ).fill()
        x += width + 30
    }
}

// Insertion point after the last line.
withShadow(color(0x6BDFFF, 0.8), blur: 24, y: 0) {
    color(0xFFFFFF).setFill()
    NSBezierPath(roundedRect: NSRect(x: body.minX + 340, y: 700 - 4 * 92 - 18, width: 16, height: 80),
                 xRadius: 8, yRadius: 8).fill()
}
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
