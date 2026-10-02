import Foundation

public enum LineEnding: String, CaseIterable {
    case lf, crlf, cr

    public var string: String {
        switch self {
        case .lf: return "\n"
        case .crlf: return "\r\n"
        case .cr: return "\r"
        }
    }

    public var label: String {
        switch self {
        case .lf: return "LF"
        case .crlf: return "CRLF"
        case .cr: return "CR"
        }
    }
}

public struct DecodedText {
    /// The text with every line ending turned into "\n".
    public var text: String
    public var encoding: String.Encoding
    public var hasBOM: Bool
    public var lineEnding: LineEnding
}

public enum TextCodec {
    /// Encodings offered in the menus, in order.
    public static let encodings: [(name: String, encoding: String.Encoding)] = [
        ("UTF-8", .utf8),
        ("UTF-16", .utf16),
        ("UTF-16 LE", .utf16LittleEndian),
        ("UTF-16 BE", .utf16BigEndian),
        ("UTF-32", .utf32),
        ("Western (ISO Latin 1)", .isoLatin1),
        ("Western (Windows 1252)", .windowsCP1252),
        ("Western (Mac OS Roman)", .macOSRoman),
        ("Central European (Windows 1250)", .windowsCP1250),
        ("Cyrillic (Windows 1251)", .windowsCP1251),
        ("Greek (Windows 1253)", .windowsCP1253),
        ("Japanese (Shift JIS)", .shiftJIS),
        ("Japanese (EUC)", .japaneseEUC),
    ]

    public static func name(of encoding: String.Encoding) -> String {
        encodings.first { $0.encoding == encoding }?.name
            ?? String.localizedName(of: encoding)
    }

    /// Decodes file contents. With no `encoding`, looks for a byte order mark, then tries UTF-8,
    /// then lets Foundation guess, and finally falls back to Latin 1, which accepts any bytes.
    public static func decode(_ data: Data, as encoding: String.Encoding? = nil) -> DecodedText? {
        var text: String?
        var used = encoding ?? .utf8
        var hasBOM = false

        if let encoding {
            if encoding == .utf8, data.starts(with: [0xEF, 0xBB, 0xBF]) {
                hasBOM = true
                text = String(data: data.dropFirst(3), encoding: .utf8)
            } else {
                text = String(data: data, encoding: encoding)
            }
        } else if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            hasBOM = true
            text = String(data: data.dropFirst(3), encoding: .utf8)
        } else if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]) || data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            // Checked before UTF-16, whose little-endian mark is the first half of this one.
            hasBOM = true
            used = .utf32
            text = String(data: data, encoding: .utf32)
        } else if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            hasBOM = true
            used = .utf16
            text = String(data: data, encoding: .utf16)
        } else if let utf8 = String(data: data, encoding: .utf8) {
            text = utf8
        } else {
            var converted: NSString?
            let guess = NSString.stringEncoding(
                for: data, encodingOptions: [.allowLossyKey: false], convertedString: &converted,
                usedLossyConversion: nil)
            if guess != 0, let converted {
                used = String.Encoding(rawValue: guess)
                text = converted as String
            } else {
                used = .isoLatin1
                text = String(data: data, encoding: .isoLatin1)
            }
        }

        guard var text else { return nil }
        let lineEnding = detectLineEnding(text)
        if lineEnding != .lf || text.utf16.contains(0x0D) {
            text = normalized(text)
        }
        return DecodedText(text: text, encoding: used, hasBOM: hasBOM, lineEnding: lineEnding)
    }

    /// Whether the bytes are something other than text: a zero byte near the start, in a file
    /// that doesn't begin with a UTF-16 or UTF-32 byte order mark.
    public static func looksBinary(_ data: Data) -> Bool {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) || data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            return false
        }
        return data.prefix(8192).contains(0)
    }

    public static func encode(
        _ text: String, encoding: String.Encoding, hasBOM: Bool, lineEnding: LineEnding
    ) -> Data? {
        let converted = lineEnding == .lf ? text : text.replacingOccurrences(of: "\n", with: lineEnding.string)
        guard var data = converted.data(using: encoding, allowLossyConversion: false) else { return nil }
        if hasBOM && encoding == .utf8 { data.insert(contentsOf: [0xEF, 0xBB, 0xBF], at: 0) }
        return data
    }

    /// The first line ending in the text decides; text without one counts as LF.
    public static func detectLineEnding(_ text: String) -> LineEnding {
        var previousWasCR = false
        for unit in text.utf16 {
            if previousWasCR { return unit == 0x0A ? .crlf : .cr }
            if unit == 0x0A { return .lf }
            previousWasCR = unit == 0x0D
        }
        return previousWasCR ? .cr : .lf
    }

    public static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}
