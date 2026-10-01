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
    /// Regular expressions that find the names listed in the symbol menu: functions, classes,
    /// headings. The first capture group is the name; without one, the whole match is.
    public var symbols: [String]?
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

public struct Token: Equatable {
    public var range: NSRange
    public var scope: Scope

    public init(range: NSRange, scope: Scope) {
        self.range = range
        self.scope = scope
    }
}

/// A named place in a document, for the symbol menu.
public struct Symbol: Equatable {
    public var name: String
    /// Where the name is in the text.
    public var range: NSRange
}

/// A syntax file turned into one regular expression that finds every token in a single pass.
public final class CompiledSyntax {
    public let definition: SyntaxDefinition
    private let regex: NSRegularExpression
    /// Capture group number and scope for each rule, in rule order.
    private let groups: [(group: Int, scope: Scope)]
    private let symbolPatterns: [NSRegularExpression]

    /// Lets a scan that starts in the middle of the text see what comes before it.
    private static let matching: NSRegularExpression.MatchingOptions = [
        .reportProgress, .withTransparentBounds, .withoutAnchoringBounds,
    ]

    private static let space = CharacterSet.whitespacesAndNewlines as NSCharacterSet

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
        symbolPatterns = try (definition.symbols ?? []).enumerated().map { index, pattern in
            do {
                return try NSRegularExpression(pattern: pattern, options: options)
            } catch {
                throw SyntaxError(message: "Symbol pattern \(index + 1) is not a valid regular expression.")
            }
        }
        do {
            regex = try NSRegularExpression(pattern: parts.joined(separator: "|"), options: options)
        } catch {
            throw SyntaxError(message: "The rules don't combine into a valid regular expression.")
        }
    }

    /// Tokens in `range`, in order. They never overlap.
    public func tokenize(_ string: NSString, range: NSRange? = nil, isCancelled: () -> Bool = { false }) -> [Token] {
        var tokens: [Token] = []
        scan(string, range: range ?? NSRange(location: 0, length: string.length), isCancelled: isCancelled) { token in
            tokens.append(token)
            return true
        }
        return tokens
    }

    /// Tokens after an edit, reusing what the last scan found.
    ///
    /// `previous` holds the old tokens with their positions already moved to fit the new text,
    /// and `edited` is the part of the new text that changed. Scanning restarts a line before the
    /// change and stops as soon as it produces a token the old scan also had after the change;
    /// from there on the two scans agree, so the old tokens are kept.
    ///
    /// A rule that matches across several lines and only matches once its end is typed (a quoted
    /// HTML attribute value, for instance) can change tokens further back than the restart point.
    /// The editor covers that with a full scan once typing pauses.
    public func retokenize(
        _ string: NSString, previous: [Token], edited: NSRange, isCancelled: () -> Bool = { false }
    ) -> [Token] {
        let length = string.length
        let editStart = min(edited.location, length)
        let editEnd = min(NSMaxRange(edited), length)

        // A rule can look ahead past white space and line breaks ("name" followed by "(" on a
        // later line), so begin at the last line before the edit that has text on it.
        var restart = string.lineRange(for: NSRange(location: editStart, length: 0)).location
        while restart > 0 {
            let line = string.lineRange(for: NSRange(location: restart - 1, length: 0))
            restart = line.location
            // Checked in place: the line can be megabytes long.
            var end = line.location
            while end < NSMaxRange(line), Self.space.characterIsMember(string.character(at: end)) { end += 1 }
            if end < NSMaxRange(line) { break }
        }
        // A token that reaches across that point has to be rescanned from its own start.
        var keep = Self.firstIndex(in: previous, endingAfter: restart)
        if keep < previous.count, previous[keep].range.location < restart {
            restart = previous[keep].range.location
            keep = Self.firstIndex(in: previous, endingAfter: restart)
        }

        var tokens = Array(previous[..<keep])
        var old = keep
        scan(string, range: NSRange(location: restart, length: length - restart), isCancelled: isCancelled) { token in
            if token.range.location >= editEnd {
                while old < previous.count, previous[old].range.location < token.range.location { old += 1 }
                if old < previous.count, previous[old] == token {
                    tokens.append(contentsOf: previous[old...])
                    return false
                }
            }
            tokens.append(token)
            return true
        }
        return tokens
    }

    /// Moves tokens to fit the text after an edit, ready for `retokenize`. `newRange` is the
    /// edited range in the text as it is now and `delta` the change in length.
    public static func shift(_ tokens: inout [Token], edited newRange: NSRange, delta: Int) {
        let location = newRange.location
        let oldEnd = location + newRange.length - delta
        var index = firstIndex(in: tokens, endingAfter: location)
        // A token around the edit stretches with it, so the next scan knows to start from it.
        if index < tokens.count, tokens[index].range.location < location {
            tokens[index].range.length = max(tokens[index].range.length + delta, location - tokens[index].range.location)
            index += 1
        }
        // Tokens that began inside the replaced text are gone.
        var after = index
        while after < tokens.count, tokens[after].range.location < oldEnd { after += 1 }
        tokens.removeSubrange(index..<after)
        if delta != 0 {
            for i in index..<tokens.count { tokens[i].range.location += delta }
        }
    }

    /// Index of the first token that ends after `location`.
    static func firstIndex(in tokens: [Token], endingAfter location: Int) -> Int {
        var low = 0
        var high = tokens.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(tokens[mid].range) > location { high = mid } else { low = mid + 1 }
        }
        return low
    }

    private func scan(_ string: NSString, range: NSRange, isCancelled: () -> Bool, each: (Token) -> Bool) {
        var count = 0
        // Progress reports arrive during a slow match too, so one bad rule can't run forever.
        regex.enumerateMatches(in: string as String, options: Self.matching, range: range) { result, _, stop in
            guard let result else {
                if isCancelled() { stop.pointee = true }
                return
            }
            guard result.range.length > 0 else { return }
            for (group, scope) in groups where result.range(at: group).location != NSNotFound {
                if !each(Token(range: result.range, scope: scope)) { stop.pointee = true }
                break
            }
            count += 1
            if count % 2048 == 0 && isCancelled() { stop.pointee = true }
        }
    }

    /// Names for the symbol menu, in the order they appear.
    public func symbols(in string: NSString) -> [Symbol] {
        var found: [Symbol] = []
        let whole = NSRange(location: 0, length: string.length)
        for pattern in symbolPatterns {
            pattern.enumerateMatches(in: string as String, options: [], range: whole) { result, _, _ in
                guard let result else { return }
                var range = result.range
                if result.numberOfRanges > 1, result.range(at: 1).location != NSNotFound { range = result.range(at: 1) }
                let name = string.substring(with: range).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { found.append(Symbol(name: String(name.prefix(100)), range: range)) }
            }
        }
        return found.sorted { $0.range.location < $1.range.location }
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
