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

// The Greek letter nu, the symbol for a neutrino, between a pink and a cyan brace.
// Coordinates are on a 132-unit grid laid over the body, with y pointing down.
let unit = body.width / 132
func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
    NSPoint(x: body.minX + x * unit, y: body.maxY - y * unit)
}
func stroke(_ path: NSBezierPath, _ hex: UInt32, width: CGFloat) {
    path.lineWidth = width * unit
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    withShadow(color(hex, 0.45), blur: 36, y: 0) {
        color(hex).setStroke()
        path.stroke()
    }
}
func quad(_ path: NSBezierPath, from: (CGFloat, CGFloat), control: (CGFloat, CGFloat), to: (CGFloat, CGFloat)) {
    // NSBezierPath only has cubic curves; this is the same curve as a quadratic one.
    let c1 = (from.0 + (control.0 - from.0) * 2 / 3, from.1 + (control.1 - from.1) * 2 / 3)
    let c2 = (to.0 + (control.0 - to.0) * 2 / 3, to.1 + (control.1 - to.1) * 2 / 3)
    path.curve(to: point(to.0, to.1), controlPoint1: point(c1.0, c1.1), controlPoint2: point(c2.0, c2.1))
}

/// A curly brace. `mirror` flips it to make the closing one.
func brace(mirror: Bool) -> NSBezierPath {
    func x(_ value: CGFloat) -> CGFloat { mirror ? 132 - value : value }
    let path = NSBezierPath()
    path.move(to: point(x(36), 28))
    quad(path, from: (x(36), 28), control: (x(24), 28), to: (x(24), 40))
    path.line(to: point(x(24), 56))
    quad(path, from: (x(24), 56), control: (x(24), 66), to: (x(16), 66))
    quad(path, from: (x(16), 66), control: (x(24), 66), to: (x(24), 76))
    path.line(to: point(x(24), 92))
    quad(path, from: (x(24), 92), control: (x(24), 104), to: (x(36), 104))
    return path
}
stroke(brace(mirror: false), 0xFF7AB2, width: 6)
stroke(brace(mirror: true), 0x6BDFFF, width: 6)

// Right arm of the nu, bowing outwards and curling back in at the top.
let arm = NSBezierPath()
arm.move(to: point(67.2, 86.2))
arm.curve(to: point(87.1, 54), controlPoint1: point(80.9, 78.8), controlPoint2: point(89.6, 63.9))
arm.curve(to: point(77.2, 51.5), controlPoint1: point(85.8, 47.8), controlPoint2: point(79.6, 46.5))
stroke(arm, 0xFFFFFF, width: 6.5)

// Left stem with the small flag at its top, drawn last so the point at the bottom is clean.
let flag = NSBezierPath()
flag.move(to: point(44.9, 54))
quad(flag, from: (44.9, 54), control: (49.9, 47.8), to: (56.1, 49))
stroke(flag, 0xFFFFFF, width: 6)
let stem = NSBezierPath()
stem.move(to: point(56.1, 49))
stem.line(to: point(67.2, 86.2))
stroke(stem, 0xFFFFFF, width: 9)
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
