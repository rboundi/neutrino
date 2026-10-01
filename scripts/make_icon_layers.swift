// Writes the SVG layers of Resources/AppIcon.icon. The shapes are defined here as strokes and
// saved as filled outlines, which every renderer draws the same way.
// Usage: swift scripts/make_icon_layers.swift
import CoreGraphics
import Foundation

let folder = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/AppIcon.icon/Assets")

/// A stroked line on a 132-unit grid, y pointing down.
struct Stroke {
    var width: CGFloat
    var build: (CGMutablePath) -> Void
}

func outline(_ stroke: Stroke) -> String {
    let line = CGMutablePath()
    stroke.build(line)
    let shape = line.copy(strokingWithWidth: stroke.width, lineCap: .round, lineJoin: .round, miterLimit: 10)
    var d = ""
    func n(_ value: CGFloat) -> String { String(format: "%.2f", value) }
    shape.applyWithBlock { element in
        let p = element.pointee.points
        switch element.pointee.type {
        case .moveToPoint: d += "M\(n(p[0].x)) \(n(p[0].y))"
        case .addLineToPoint: d += "L\(n(p[0].x)) \(n(p[0].y))"
        case .addQuadCurveToPoint: d += "Q\(n(p[0].x)) \(n(p[0].y)) \(n(p[1].x)) \(n(p[1].y))"
        case .addCurveToPoint: d += "C\(n(p[0].x)) \(n(p[0].y)) \(n(p[1].x)) \(n(p[1].y)) \(n(p[2].x)) \(n(p[2].y))"
        case .closeSubpath: d += "Z"
        @unknown default: break
        }
    }
    return d
}

func write(_ name: String, color: String, _ strokes: [Stroke]) throws {
    let paths = strokes.map { "  <path d=\"\(outline($0))\" fill=\"\(color)\"/>" }.joined(separator: "\n")
    let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1024\" height=\"1024\" viewBox=\"0 0 132 132\">\n\(paths)\n</svg>\n"
    try svg.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
}

func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

/// A curly brace; `mirror` flips it to make the closing one.
func brace(mirror: Bool) -> Stroke {
    func x(_ value: CGFloat) -> CGFloat { mirror ? 132 - value : value }
    return Stroke(width: 6) { path in
        path.move(to: point(x(36), 28))
        path.addQuadCurve(to: point(x(24), 40), control: point(x(24), 28))
        path.addLine(to: point(x(24), 56))
        path.addQuadCurve(to: point(x(16), 66), control: point(x(24), 66))
        path.addQuadCurve(to: point(x(24), 76), control: point(x(24), 66))
        path.addLine(to: point(x(24), 92))
        path.addQuadCurve(to: point(x(36), 104), control: point(x(24), 104))
    }
}

// The Greek letter nu: a flag on the left stem, and a right arm that bows out and curls back in.
let nu = [
    Stroke(width: 6.5) { path in
        path.move(to: point(67.2, 86.2))
        path.addCurve(to: point(87.1, 54), control1: point(80.9, 78.8), control2: point(89.6, 63.9))
        path.addCurve(to: point(77.2, 51.5), control1: point(85.8, 47.8), control2: point(79.6, 46.5))
    },
    Stroke(width: 6) { path in
        path.move(to: point(44.9, 54))
        path.addQuadCurve(to: point(56.1, 49), control: point(49.9, 47.8))
    },
    Stroke(width: 9) { path in
        path.move(to: point(56.1, 49))
        path.addLine(to: point(67.2, 86.2))
    },
]

try write("brace-left.svg", color: "#FF7AB2", [brace(mirror: false)])
try write("brace-right.svg", color: "#6BDFFF", [brace(mirror: true)])
try write("nu.svg", color: "#FFFFFF", nu)
print("layers written to \(folder.path)")
