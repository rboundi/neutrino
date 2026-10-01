import AppKit
import NeutrinoCore

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
    static let theme = "theme"
    static let filterCommand = "filterCommand"
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
    static let autosave = "autosave"
    static let detectIndentation = "detectIndentation"
    /// The column of the page guide; 0 for none.
    static let pageGuide = "pageGuide"
    static let checkSpelling = "checkSpelling"
    static let indentGuides = "indentGuides"
    static let markTrailingSpaces = "markTrailingSpaces"
    static let showColours = "showColours"
    /// Where the caret was in recently closed files, oldest first, as "location\tpath".
    static let positions = "positions"
    /// The macOS setting that keeps an app's windows, and the unsaved text in them, across a quit.
    static let keepWindows = "NSQuitAlwaysKeepsWindows"
    static let checkForUpdates = "checkForUpdates"
    static let lastUpdateCheck = "lastUpdateCheck"
    static let findRegex = "findRegex"
    static let findCaseSensitive = "findCaseSensitive"
    static let findWholeWord = "findWholeWord"
    static let findHistory = "findHistory"

    static let defaultFontSize = 13.0
    /// Seconds without typing before a changed document is saved automatically.
    static let autosaveDelay = 5.0

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
            autosave: true,
            detectIndentation: true,
            pageGuide: 0,
            checkSpelling: false,
            indentGuides: false,
            markTrailingSpaces: false,
            showColours: false,
            checkForUpdates: true,
        ])
    }

    /// Quitting keeps every window and its unsaved text for the next launch, without asking to
    /// save. This has to be written to the app's own settings: the system-wide setting, which is
    /// off by default, would otherwise win over a registered default.
    static func keepWindowsByDefault() {
        let defaults = UserDefaults.standard
        let own = Bundle.main.bundleIdentifier.flatMap { defaults.persistentDomain(forName: $0) }
        guard own?[keepWindows] == nil else { return }
        // Versions before 1.0.2 had their own "Reopen documents" setting; keep that choice.
        let reopen = own?["reopenDocuments"] as? Bool ?? true
        defaults.set(reopen, forKey: keepWindows)
    }

    /// Makes the editor text larger or smaller for every document, now and in future.
    /// A step of zero goes back to the standard size.
    static func changeFontSize(by step: Double) {
        let defaults = UserDefaults.standard
        let size = step == 0 ? defaultFontSize : defaults.double(forKey: fontSize) + step
        defaults.set(min(max(size, 8), 48), forKey: fontSize)
    }

    /// The caret position remembered for a file, if it was open before.
    static func position(for url: URL) -> Int? {
        let suffix = "\t" + url.path
        let entry = UserDefaults.standard.stringArray(forKey: positions)?.last { $0.hasSuffix(suffix) }
        return entry.flatMap { Int($0.dropLast(suffix.count)) }
    }

    /// Remembers where the caret is in a file, for the next time it is opened.
    static func setPosition(_ location: Int, for url: URL) {
        let suffix = "\t" + url.path
        var entries = UserDefaults.standard.stringArray(forKey: positions) ?? []
        let entry = "\(location)" + suffix
        if entries.last == entry { return }
        entries.removeAll { $0.hasSuffix(suffix) }
        // The start of a file is where it opens anyway.
        if location > 0 { entries.append(entry) }
        UserDefaults.standard.set(Array(entries.suffix(300)), forKey: positions)
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
    var pageGuide: Int
    var checkSpelling: Bool
    var indentGuides: Bool
    var markTrailingSpaces: Bool
    /// Whether hex colours such as #3E8087 are underlined in their own colour.
    var showColours: Bool
    /// The installed theme in use; empty for the built-in colours.
    var theme: String

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
            autoCloseBrackets: defaults.bool(forKey: Prefs.autoCloseBrackets),
            pageGuide: min(max(defaults.integer(forKey: Prefs.pageGuide), 0), 400),
            checkSpelling: defaults.bool(forKey: Prefs.checkSpelling),
            indentGuides: defaults.bool(forKey: Prefs.indentGuides),
            markTrailingSpaces: defaults.bool(forKey: Prefs.markTrailingSpaces),
            showColours: defaults.bool(forKey: Prefs.showColours),
            theme: defaults.string(forKey: Prefs.theme) ?? "")
    }

    /// These settings with the ones an `.editorconfig` file sets for a document laid over them.
    func applying(_ config: EditorConfig) -> EditorStyle {
        var style = self
        if let spaces = config.indentWithSpaces { style.insertSpaces = spaces }
        if let width = config.indentWidth { style.tabWidth = width }
        return style
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
