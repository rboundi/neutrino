import AppKit
import NeutrinoCore

/// Editor colours. Each one resolves for light or dark when it is drawn.
enum Theme {
    static let text = NSColor.textColor
    static let background = NSColor.textBackgroundColor
    static let gutterText = NSColor.tertiaryLabelColor
    static let invisibles = NSColor.quaternaryLabelColor
    static let currentLine = dynamic(light: 0x000000, dark: 0xFFFFFF, alpha: 0.05)
    static let findMatch = dynamic(light: 0xFFE14D, dark: 0x8A6D00, alpha: 0.55)

    private static let colors: [Scope: NSColor] = [
        .comment: dynamic(light: 0x6A737D, dark: 0x7F8C98),
        .string: dynamic(light: 0xC41A16, dark: 0xFF8170),
        .keyword: dynamic(light: 0xAD3DA4, dark: 0xFF7AB2),
        .number: dynamic(light: 0x272AD8, dark: 0xD9C97C),
        .type: dynamic(light: 0x3E8087, dark: 0x6BDFFF),
        .function: dynamic(light: 0x4B21B0, dark: 0xB281EB),
        .constant: dynamic(light: 0x9A5B00, dark: 0xFFA14F),
        .variable: dynamic(light: 0x0F68A0, dark: 0x4EB0CC),
        .tag: dynamic(light: 0xAD3DA4, dark: 0xFF7AB2),
        .attribute: dynamic(light: 0x815F03, dark: 0xD9C97C),
        .operator: dynamic(light: 0x5C6773, dark: 0xA3B1BF),
        .heading: dynamic(light: 0x0F68A0, dark: 0x6BDFFF),
        .link: dynamic(light: 0x0F68A0, dark: 0x4EB0CC),
        .emphasis: dynamic(light: 0x9A5B00, dark: 0xFFA14F),
        .inserted: dynamic(light: 0x1A7F37, dark: 0x67D97A),
        .deleted: dynamic(light: 0xC41A16, dark: 0xFF8170),
    ]

    static func color(for scope: Scope) -> NSColor {
        colors[scope] ?? text
    }

    private static func dynamic(light: UInt32, dark: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
        }
    }
}
