import AppKit

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// UserDefaults keys and helpers. Everything the app remembers lives here.
enum Prefs {
    static let appearance = "appearance"
    static let fontName = "fontName"
    static let fontSize = "fontSize"
    static let tabWidth = "tabWidth"
    static let insertSpaces = "insertSpaces"
    static let wrapLines = "wrapLines"
    static let lineNumbers = "lineNumbers"
    static let showInvisibles = "showInvisibles"
    static let highlightCurrentLine = "highlightCurrentLine"
    static let autoIndent = "autoIndent"
    static let autoCloseBrackets = "autoCloseBrackets"
    static let trimTrailingWhitespace = "trimTrailingWhitespace"
    static let ensureFinalNewline = "ensureFinalNewline"
    static let reopenDocuments = "reopenDocuments"
    static let openDocuments = "openDocuments"
    static let checkForUpdates = "checkForUpdates"
    static let lastUpdateCheck = "lastUpdateCheck"
    static let latestVersion = "latestVersion"
    static let latestVersionURL = "latestVersionURL"
    static let findRegex = "findRegex"
    static let findCaseSensitive = "findCaseSensitive"
    static let findWholeWord = "findWholeWord"
    static let findHistory = "findHistory"

    static let defaultFontSize = 13.0

    static func register() {
        UserDefaults.standard.register(defaults: [
            appearance: AppearanceMode.system.rawValue,
            fontName: "",
            fontSize: defaultFontSize,
            tabWidth: 4,
            insertSpaces: true,
            wrapLines: true,
            lineNumbers: true,
            showInvisibles: false,
            highlightCurrentLine: true,
            autoIndent: true,
            autoCloseBrackets: true,
            trimTrailingWhitespace: false,
            ensureFinalNewline: false,
            reopenDocuments: true,
            checkForUpdates: true,
        ])
    }

    static var appearanceMode: AppearanceMode {
        AppearanceMode(rawValue: UserDefaults.standard.string(forKey: appearance) ?? "") ?? .system
    }
}

/// The editor settings as one value, so windows can tell when something they show has changed.
struct EditorStyle: Equatable {
    var fontName: String
    var fontSize: Double
    var tabWidth: Int
    var insertSpaces: Bool
    var wrapLines: Bool
    var lineNumbers: Bool
    var showInvisibles: Bool
    var highlightCurrentLine: Bool
    var autoIndent: Bool
    var autoCloseBrackets: Bool

    static var current: EditorStyle {
        let defaults = UserDefaults.standard
        return EditorStyle(
            fontName: defaults.string(forKey: Prefs.fontName) ?? "",
            fontSize: min(max(defaults.double(forKey: Prefs.fontSize), 8), 48),
            tabWidth: min(max(defaults.integer(forKey: Prefs.tabWidth), 1), 16),
            insertSpaces: defaults.bool(forKey: Prefs.insertSpaces),
            wrapLines: defaults.bool(forKey: Prefs.wrapLines),
            lineNumbers: defaults.bool(forKey: Prefs.lineNumbers),
            showInvisibles: defaults.bool(forKey: Prefs.showInvisibles),
            highlightCurrentLine: defaults.bool(forKey: Prefs.highlightCurrentLine),
            autoIndent: defaults.bool(forKey: Prefs.autoIndent),
            autoCloseBrackets: defaults.bool(forKey: Prefs.autoCloseBrackets))
    }

    var font: NSFont {
        let size = CGFloat(fontSize)
        if !fontName.isEmpty, let font = NSFont(name: fontName, size: size) { return font }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Attributes for all text in the editor. Colours come from temporary attributes on top.
    var textAttributes: [NSAttributedString.Key: Any] {
        let font = self.font
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = []
        paragraph.defaultTabInterval = (" " as NSString).size(withAttributes: [.font: font]).width * CGFloat(tabWidth)
        return [.font: font, .foregroundColor: Theme.text, .paragraphStyle: paragraph]
    }
}
