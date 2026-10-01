import Foundation

/// The header of a theme file: enough to list it.
public struct ThemeInfo: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var version: Int
    public var dark: Bool
}

/// A theme file as stored on disk and in the repository's `themes` folder. Colours are "#RRGGBB".
public struct ThemeDefinition: Codable {
    public var id: String
    public var name: String
    public var version: Int
    /// Whether the window around the text should use the dark appearance.
    public var dark: Bool
    public var background: String
    public var text: String
    public var selection: String
    public var currentLine: String
    public var lineNumbers: String
    public var findMatch: String
    /// Colour for each scope a syntax can name; scopes left out use the text colour.
    public var scopes: [String: String]

    public var info: ThemeInfo { ThemeInfo(id: id, name: name, version: version, dark: dark) }

    /// Red, green and blue from 0 to 1, or nil if the string isn't "#RRGGBB".
    public static func rgb(_ hex: String) -> (red: Double, green: Double, blue: Double)? {
        guard hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return (Double((value >> 16) & 0xff) / 255, Double((value >> 8) & 0xff) / 255, Double(value & 0xff) / 255)
    }

    /// Checks that every colour can be read, so a broken file is refused when it is installed.
    public func validate() throws {
        guard SyntaxInfo.isValidID(id) else { throw SyntaxError(message: "Invalid id “\(id)”.") }
        let all = [background, text, selection, currentLine, lineNumbers, findMatch] + Array(scopes.values)
        if let bad = all.first(where: { Self.rgb($0) == nil }) {
            throw SyntaxError(message: "“\(bad)” is not a colour. Use the form #RRGGBB.")
        }
    }
}

public struct ThemeCatalog: Codable {
    public var themes: [ThemeInfo]
}
