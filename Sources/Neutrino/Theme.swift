import AppKit
import NeutrinoCore

/// Editor colours: those of the installed theme in use, or the built-in ones, which follow
/// the light or dark appearance when they are drawn.
enum Theme {
    static var text: NSColor { ThemeStore.shared.active?.text ?? .textColor }
    static var background: NSColor { ThemeStore.shared.active?.background ?? .textBackgroundColor }
    static var gutterText: NSColor { ThemeStore.shared.active?.lineNumbers ?? .tertiaryLabelColor }
    static var invisibles: NSColor { ThemeStore.shared.active?.text.withAlphaComponent(0.25) ?? .quaternaryLabelColor }
    static var currentLine: NSColor { ThemeStore.shared.active?.currentLine ?? defaultCurrentLine }
    static var findMatch: NSColor { ThemeStore.shared.active?.findMatch ?? defaultFindMatch }
    static var selection: NSColor { ThemeStore.shared.active?.selection ?? .selectedTextBackgroundColor }
    static var bracketMatch: NSColor { text.withAlphaComponent(0.22) }
    /// Behind the other places the selected word occurs.
    static var occurrence: NSColor { text.withAlphaComponent(0.13) }
    static var pageGuide: NSColor { text.withAlphaComponent(0.12) }
    static var trailingSpace: NSColor { NSColor.systemRed.withAlphaComponent(0.3) }

    /// The built-in colours as they are on a light background, for printing on paper.
    static func printColor(for scope: Scope) -> NSColor {
        var color = NSColor.black
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            color = defaults[scope]?.usingColorSpace(.sRGB) ?? .black
        }
        return color
    }

    private static let defaultCurrentLine = dynamic(light: 0x000000, dark: 0xFFFFFF, alpha: 0.05)
    private static let defaultFindMatch = dynamic(light: 0xFFE14D, dark: 0x8A6D00, alpha: 0.55)

    private static let defaults: [Scope: NSColor] = [
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
        if let theme = ThemeStore.shared.active { return theme.scopes[scope] ?? theme.text }
        return defaults[scope] ?? text
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

/// A theme file turned into colours.
struct LoadedTheme {
    let dark: Bool
    let background: NSColor
    let text: NSColor
    let selection: NSColor
    let currentLine: NSColor
    let lineNumbers: NSColor
    let findMatch: NSColor
    let scopes: [Scope: NSColor]

    init?(data: Data) {
        guard let definition = try? JSONDecoder().decode(ThemeDefinition.self, from: data),
            (try? definition.validate()) != nil
        else { return nil }
        func color(_ hex: String) -> NSColor {
            let rgb = ThemeDefinition.rgb(hex) ?? (0, 0, 0)
            return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        }
        dark = definition.dark
        background = color(definition.background)
        text = color(definition.text)
        selection = color(definition.selection)
        currentLine = color(definition.currentLine)
        lineNumbers = color(definition.lineNumbers)
        findMatch = color(definition.findMatch)
        var scopes: [Scope: NSColor] = [:]
        for (name, hex) in definition.scopes {
            if let scope = Scope(rawValue: name) { scopes[scope] = color(hex) }
        }
        self.scopes = scopes
    }
}

/// Theme files on this Mac, the list of published ones, and the one in use.
final class ThemeStore {
    static let shared = ThemeStore()
    static let didChange = Notification.Name("ThemeStoreDidChange")

    let files = PackageFolder<ThemeInfo>(
        name: "themes", folder: "Themes", didChange: ThemeStore.didChange,
        decodeCatalog: { (try? JSONDecoder().decode(ThemeCatalog.self, from: $0))?.themes },
        validate: { data in
            let definition: ThemeDefinition
            do {
                definition = try JSONDecoder().decode(ThemeDefinition.self, from: data)
            } catch {
                throw SyntaxError(message: "Not a theme file.")
            }
            try definition.validate()
            return definition.id
        },
        label: \.name)

    /// The theme in use, looked up once and kept until the setting or the files change.
    private var cached: (id: String, theme: LoadedTheme?)?

    private init() {
        files.onChange = { [weak self] _ in self?.cached = nil }
        // Only a change of theme drops the cached one, not every settings change.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            if let cached = self?.cached, cached.id != Self.chosenID { self?.cached = nil }
        }
    }

    private static var chosenID: String {
        UserDefaults.standard.string(forKey: Prefs.theme) ?? ""
    }

    /// The installed theme chosen in Settings; nil means the built-in colours.
    /// Colour lookups call this for every token, so it must not read the settings each time.
    var active: LoadedTheme? {
        if let cached { return cached.theme }
        let id = Self.chosenID
        let theme = id.isEmpty ? nil : files.data(for: id).flatMap(LoadedTheme.init(data:))
        cached = (id, theme)
        return theme
    }

    /// The window appearance that goes with the colours in use.
    var appearance: NSAppearance? {
        guard let active else { return Prefs.appearanceMode.nsAppearance }
        return NSAppearance(named: active.dark ? .darkAqua : .aqua)
    }
}
