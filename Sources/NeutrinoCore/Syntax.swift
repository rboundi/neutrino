import Foundation

/// What a piece of highlighted text is. Syntax files name these; the app maps them to colours.
public enum Scope: String, CaseIterable {
    case comment, string, keyword, number, type, function, constant, variable
    case tag, attribute, `operator`, heading, link, emphasis, inserted, deleted
}

/// One rule of a syntax file. Exactly one of `match`, `begin`/`end` or `words` is used.
public struct SyntaxRule: Codable {
    public var scope: String
    /// A regular expression.
    public var match: String?
    /// Regular expressions for the start and end of a region such as a string or block comment.
    public var begin: String?
    public var end: String?
    /// A regular expression for the escape character inside a region, usually a backslash.
    public var escape: String?
    /// Whether a region may continue past the end of the line. Defaults to true.
    public var multiline: Bool?
    /// Whole words, matched literally.
    public var words: [String]?
}

/// The header of a syntax file: everything needed to list it and to pick it for a file.
public struct SyntaxInfo: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var version: Int
    public var extensions: [String]
    public var filenames: [String]?
    public var firstLine: String?

    public init(id: String, name: String, version: Int, extensions: [String], filenames: [String]? = nil,
                firstLine: String? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.extensions = extensions
        self.filenames = filenames
        self.firstLine = firstLine
    }

    public static func isValidID(_ id: String) -> Bool {
        id.range(of: "^[a-z0-9][a-z0-9+#._-]{0,40}$", options: .regularExpression) != nil
    }
}

/// A syntax file as stored on disk and in the repository's `syntaxes` folder.
public struct SyntaxDefinition: Codable {
    public var id: String
    public var name: String
    public var version: Int
    public var extensions: [String]
    public var filenames: [String]?
    public var firstLine: String?
    public var lineComment: String?
    public var blockComment: [String]?
    public var caseInsensitive: Bool?
    /// For languages that need tab characters, such as Makefiles. Overrides the indentation setting.
    public var indentWithTabs: Bool?
    /// For languages where a line ending in a colon opens a block, such as Python.
    public var indentAfterColon: Bool?
    public var rules: [SyntaxRule]

    public var info: SyntaxInfo {
        SyntaxInfo(id: id, name: name, version: version, extensions: extensions, filenames: filenames,
                   firstLine: firstLine)
    }
}

public struct SyntaxError: Error, LocalizedError {
    public var message: String
    public var errorDescription: String? { message }

    public init(message: String) {
        self.message = message
    }
}

public struct Token {
    public var range: NSRange
    public var scope: Scope
}

/// A syntax file turned into one regular expression that finds every token in a single pass.
public final class CompiledSyntax {
    public let definition: SyntaxDefinition
    private let regex: NSRegularExpression
    /// Capture group number and scope for each rule, in rule order.
    private let groups: [(group: Int, scope: Scope)]

    public convenience init(data: Data) throws {
        let definition: SyntaxDefinition
        do {
            definition = try JSONDecoder().decode(SyntaxDefinition.self, from: data)
        } catch {
            throw SyntaxError(message: "Not a syntax file: \(Self.describe(error))")
        }
        try self.init(definition)
    }

    public init(_ definition: SyntaxDefinition) throws {
        guard SyntaxInfo.isValidID(definition.id) else {
            throw SyntaxError(message: "Invalid id “\(definition.id)”.")
        }
        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        if definition.caseInsensitive == true { options.insert(.caseInsensitive) }

        var parts: [String] = []
        var groups: [(group: Int, scope: Scope)] = []
        var nextGroup = 1
        for (index, rule) in definition.rules.enumerated() {
            let pattern = try Self.pattern(for: rule, index: index)
            let single: NSRegularExpression
            do {
                single = try NSRegularExpression(pattern: pattern, options: options)
            } catch {
                throw SyntaxError(message: "Rule \(index + 1) is not a valid regular expression.")
            }
            // Rules with a scope this version doesn't know still take part, so the text they
            // cover isn't claimed by a later rule; they just aren't coloured.
            if let scope = Scope(rawValue: rule.scope) {
                groups.append((nextGroup, scope))
            }
            parts.append("(\(pattern))")
            nextGroup += 1 + single.numberOfCaptureGroups
        }
        self.definition = definition
        self.groups = groups
        do {
            regex = try NSRegularExpression(pattern: parts.joined(separator: "|"), options: options)
        } catch {
            throw SyntaxError(message: "The rules don't combine into a valid regular expression.")
        }
    }

    /// Tokens in `range`, in order. They never overlap.
    public func tokenize(_ string: NSString, range: NSRange? = nil, isCancelled: () -> Bool = { false }) -> [Token] {
        var tokens: [Token] = []
        var count = 0
        let range = range ?? NSRange(location: 0, length: string.length)
        // Progress reports arrive during a slow match too, so one bad rule can't run forever.
        regex.enumerateMatches(in: string as String, options: [.reportProgress], range: range) { result, _, stop in
            guard let result else {
                if isCancelled() { stop.pointee = true }
                return
            }
            guard result.range.length > 0 else { return }
            for (group, scope) in groups where result.range(at: group).location != NSNotFound {
                tokens.append(Token(range: result.range, scope: scope))
                break
            }
            count += 1
            if count % 2048 == 0 && isCancelled() { stop.pointee = true }
        }
        return tokens
    }

    private static func pattern(for rule: SyntaxRule, index: Int) throws -> String {
        if let match = rule.match {
            return match
        }
        if let begin = rule.begin, let end = rule.end {
            let flag = rule.multiline == false ? "-s" : "s"
            let body = rule.escape.map { "(?:\($0).|(?!\(end)).)*+" } ?? "(?:(?!\(end)).)*+"
            return "(?\(flag):\(begin)\(body)(?:\(end))?)"
        }
        if let words = rule.words, !words.isEmpty {
            // Longest first, so "elseif" isn't cut short by "else" when a word contains punctuation.
            let escaped = words.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:))
            return "(?<![\\w$])(?:\(escaped.joined(separator: "|")))(?![\\w$])"
        }
        throw SyntaxError(message: "Rule \(index + 1) needs “match”, “begin” and “end”, or “words”.")
    }

    private static func describe(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return error.localizedDescription }
        switch error {
        case .keyNotFound(let key, _): return "“\(key.stringValue)” is missing."
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "“\(context.codingPath.map(\.stringValue).joined(separator: "."))” has the wrong type."
        case .dataCorrupted: return "the JSON is malformed."
        @unknown default: return error.localizedDescription
        }
    }
}

/// The list of syntaxes published in the repository (`syntaxes/index.json`).
public struct SyntaxCatalog: Codable {
    public var syntaxes: [SyntaxInfo]

    public init(syntaxes: [SyntaxInfo] = []) {
        self.syntaxes = syntaxes
    }

    /// The syntax for a file, going by its name, then its extension, then its first line.
    public static func match(_ syntaxes: [SyntaxInfo], filename: String, firstLine: String) -> SyntaxInfo? {
        if let hit = syntaxes.first(where: { $0.filenames?.contains(filename) == true }) { return hit }
        let ext = (filename as NSString).pathExtension.lowercased()
        if !ext.isEmpty, let hit = syntaxes.first(where: { $0.extensions.contains(ext) }) { return hit }
        guard !firstLine.isEmpty else { return nil }
        return syntaxes.first { info in
            guard let pattern = info.firstLine else { return false }
            return firstLine.range(of: pattern, options: .regularExpression) != nil
        }
    }
}
