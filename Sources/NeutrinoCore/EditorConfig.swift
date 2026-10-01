import Foundation

/// The settings Neutrino takes from `.editorconfig` files. Nil means "not set there".
public struct EditorConfig: Equatable {
    public var indentWithSpaces: Bool?
    /// Width of one level of indentation, which is also how wide a tab is shown.
    public var indentWidth: Int?
    public var trimTrailingWhitespace: Bool?
    public var insertFinalNewline: Bool?

    public init() {}

    public var isEmpty: Bool { self == EditorConfig() }

    /// Reads every `.editorconfig` from the file's folder upwards, stopping at one with `root = true`.
    /// Files nearer to the document win, and within a file later sections win.
    public static func load(
        for file: URL, read: (URL) -> String? = { try? String(contentsOf: $0, encoding: .utf8) }
    ) -> EditorConfig {
        var files: [(folder: URL, text: String)] = []
        var folder = file.deletingLastPathComponent().standardizedFileURL
        while true {
            if let text = read(folder.appendingPathComponent(".editorconfig")) {
                files.append((folder, text))
                if parse(text).root { break }
            }
            let parent = folder.deletingLastPathComponent().standardizedFileURL
            if parent.path == folder.path { break }
            folder = parent
        }

        var pairs: [String: String] = [:]
        for (folder, text) in files.reversed() {
            let prefix = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
            guard file.standardizedFileURL.path.hasPrefix(prefix) else { continue }
            let relative = String(file.standardizedFileURL.path.dropFirst(prefix.count))
            for section in parse(text).sections where matches(pattern: section.pattern, path: relative) {
                pairs.merge(section.pairs) { _, new in new }
            }
        }

        var config = EditorConfig()
        switch pairs["indent_style"] {
        case "space": config.indentWithSpaces = true
        case "tab": config.indentWithSpaces = false
        default: break
        }
        let size = pairs["indent_size"].flatMap { Int($0) } ?? pairs["tab_width"].flatMap { Int($0) }
        if let size, (1...16).contains(size) { config.indentWidth = size }
        config.trimTrailingWhitespace = pairs["trim_trailing_whitespace"].flatMap(bool)
        config.insertFinalNewline = pairs["insert_final_newline"].flatMap(bool)
        return config
    }

    private static func bool(_ value: String) -> Bool? {
        value == "true" ? true : value == "false" ? false : nil
    }

    static func parse(_ text: String) -> (root: Bool, sections: [(pattern: String, pairs: [String: String])]) {
        var root = false
        var sections: [(pattern: String, pairs: [String: String])] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                sections.append((String(line.dropFirst().dropLast()), [:]))
            } else if let equals = line.firstIndex(of: "=") {
                let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces).lowercased()
                if sections.isEmpty {
                    if key == "root" { root = value == "true" }
                } else {
                    sections[sections.count - 1].pairs[key] = value
                }
            }
        }
        return (root, sections)
    }

    /// Whether an EditorConfig glob matches a path given relative to the folder of the config file.
    static func matches(pattern: String, path: String) -> Bool {
        var glob = pattern
        var regex = "^"
        if glob.contains("/") {
            if glob.hasPrefix("/") { glob.removeFirst() }
        } else {
            // A pattern without a slash applies to the file name in any subfolder.
            regex += "(?:.*/)?"
        }
        let chars = Array(glob)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "*":
                if i + 1 < chars.count, chars[i + 1] == "*" {
                    regex += ".*"
                    i += 1
                } else {
                    regex += "[^/]*"
                }
            case "?":
                regex += "[^/]"
            case "[":
                if let close = chars[(i + 1)...].firstIndex(of: "]") {
                    var body = String(chars[(i + 1)..<close])
                    if body.hasPrefix("!") { body = "^" + body.dropFirst() }
                    regex += "[" + body.replacingOccurrences(of: "\\", with: "\\\\") + "]"
                    i = close
                } else {
                    regex += "\\["
                }
            case "{":
                if let close = chars[(i + 1)...].firstIndex(of: "}") {
                    let body = String(chars[(i + 1)..<close])
                    let numbers = body.components(separatedBy: "..").compactMap { Int($0) }
                    if body.contains(".."), numbers.count == 2, numbers[0] <= numbers[1], numbers[1] - numbers[0] <= 500 {
                        regex += "(?:" + (numbers[0]...numbers[1]).map(String.init).joined(separator: "|") + ")"
                    } else if body.contains(",") {
                        let options = body.components(separatedBy: ",").map(NSRegularExpression.escapedPattern(for:))
                        regex += "(?:" + options.joined(separator: "|") + ")"
                    } else {
                        regex += NSRegularExpression.escapedPattern(for: "{" + body + "}")
                    }
                    i = close
                } else {
                    regex += "\\{"
                }
            default:
                regex += NSRegularExpression.escapedPattern(for: String(c))
            }
            i += 1
        }
        regex += "$"
        return path.range(of: regex, options: .regularExpression) != nil
    }
}
