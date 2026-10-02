import Foundation

public struct SearchOptions: Equatable {
    public var regex = false
    public var caseSensitive = false
    public var wholeWord = false

    public init(regex: Bool = false, caseSensitive: Bool = false, wholeWord: Bool = false) {
        self.regex = regex
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
    }
}

public struct SearchError: Error, LocalizedError {
    public var message: String
    public var errorDescription: String? { message }

    public init(message: String) {
        self.message = message
    }
}

/// A compiled search. Plain-text searches are escaped and run through the same regex engine.
public struct SearchQuery {
    public let regex: NSRegularExpression
    public let options: SearchOptions

    /// Lets lookbehind and \b see the text around a search limited to the selection.
    private static let matching: NSRegularExpression.MatchingOptions = [.withTransparentBounds, .withoutAnchoringBounds]

    public init(pattern: String, options: SearchOptions) throws {
        guard !pattern.isEmpty else { throw SearchError(message: "Empty pattern") }
        var source = options.regex ? pattern : NSRegularExpression.escapedPattern(for: pattern)
        if options.wholeWord { source = "(?<![\\w])(?:\(source))(?![\\w])" }
        var flags: NSRegularExpression.Options = [.anchorsMatchLines]
        if !options.caseSensitive { flags.insert(.caseInsensitive) }
        do {
            regex = try NSRegularExpression(pattern: source, options: flags)
        } catch {
            throw SearchError(message: "Invalid regular expression")
        }
        self.options = options
    }

    public func matches(
        in string: NSString, range: NSRange? = nil, isCancelled: () -> Bool = { false }
    ) -> [NSTextCheckingResult] {
        var results: [NSTextCheckingResult] = []
        let range = range ?? NSRange(location: 0, length: string.length)
        // Progress reports arrive during a slow match too, so a search can be abandoned mid-match.
        var options = Self.matching
        options.insert(.reportProgress)
        regex.enumerateMatches(in: string as String, options: options, range: range) { result, _, stop in
            guard let result else {
                if isCancelled() { stop.pointee = true }
                return
            }
            results.append(result)
            if results.count % 2048 == 0 && isCancelled() { stop.pointee = true }
        }
        return results
    }

    public func ranges(
        in string: NSString, range: NSRange? = nil, isCancelled: () -> Bool = { false }
    ) -> [NSRange] {
        matches(in: string, range: range, isCancelled: isCancelled).map(\.range)
    }

    /// How much text around a selected match is looked at, for lookbehind and lookahead.
    static let matchContext = 10_000

    /// The match covering exactly `range`, if there is one. Used to replace the selected match.
    public func match(at range: NSRange, in string: NSString) -> NSTextCheckingResult? {
        guard range.location >= 0, NSMaxRange(range) <= string.length else { return nil }
        // Only the text near the match is handed to the regex: the whole of a mutable text
        // would be copied first, on every Replace.
        let start = max(range.location - Self.matchContext, 0)
        let end = min(NSMaxRange(range) + Self.matchContext, string.length)
        let window = string.substring(with: NSRange(location: start, length: end - start))
        let rest = NSRange(location: range.location - start, length: end - range.location)
        var options = Self.matching
        options.insert(.anchored)
        guard let result = regex.firstMatch(in: window, options: options, range: rest),
            result.range == NSRange(location: range.location - start, length: range.length)
        else { return nil }
        return result.adjustingRanges(offset: start)
    }
}

/// The text a match is replaced with.
///
/// For plain-text searches the template is used as it is. For regex searches it understands:
/// - `$1`…`$99`, `\1`…`\9`, `${1}` and `${name}` for capture groups, `$0` or `$&` for the whole match
/// - `\n`, `\t`, `\r`, `\\`, `\$`
/// - `\U…\E` upper case, `\L…\E` lower case, `\u` and `\l` for the next character only
public struct Replacement {
    private enum Piece {
        case literal(String)
        case group(Int)
        /// The digits after a `$`. How many of them name a group depends on the pattern.
        case digits(String)
        case named(String)
        case upper, lower, endCase, nextUpper, nextLower
    }

    private let pieces: [Piece]

    public init(template: String, isRegex: Bool) {
        pieces = isRegex ? Self.parse(template) : [.literal(template)]
    }

    public func expand(_ match: NSTextCheckingResult, in string: NSString) -> String {
        if pieces.count == 1, case .literal(let text) = pieces[0] { return text }
        var output = ""
        var mode = Piece.endCase
        var next: Piece?

        func append(_ text: String) {
            guard !text.isEmpty else { return }
            var text = text
            switch mode {
            case .upper: text = text.uppercased()
            case .lower: text = text.lowercased()
            default: break
            }
            if let pending = next {
                let head = String(text.prefix(1))
                text = (isUpper(pending) ? head.uppercased() : head.lowercased()) + text.dropFirst()
                next = nil
            }
            output += text
        }
        func isUpper(_ piece: Piece) -> Bool {
            if case .nextUpper = piece { return true }
            return false
        }
        func text(of range: NSRange) -> String {
            range.location == NSNotFound ? "" : string.substring(with: range)
        }

        for piece in pieces {
            switch piece {
            case .literal(let literal): append(literal)
            case .group(let number):
                append(number < match.numberOfRanges ? text(of: match.range(at: number)) : "")
            case .digits(let digits):
                // The longest prefix that names a group; the rest is ordinary text, so "$10" with
                // one group is group 1 followed by "0".
                var used = digits.count
                while used > 1, Int(digits.prefix(used))! >= match.numberOfRanges { used -= 1 }
                let number = Int(digits.prefix(used))!
                if number < match.numberOfRanges {
                    append(text(of: match.range(at: number)))
                    append(String(digits.dropFirst(used)))
                }
            case .named(let name):
                if let number = Int(name) {
                    append(number < match.numberOfRanges ? text(of: match.range(at: number)) : "")
                } else {
                    append(text(of: match.range(withName: name)))
                }
            case .upper, .lower, .endCase: mode = piece
            case .nextUpper, .nextLower: next = piece
            }
        }
        return output
    }

    private static func parse(_ template: String) -> [Piece] {
        var pieces: [Piece] = []
        var literal = ""
        let chars = Array(template)
        var i = 0

        func flush() {
            if !literal.isEmpty {
                pieces.append(.literal(literal))
                literal = ""
            }
        }
        func digits(from start: Int, max: Int) -> (value: Int, end: Int)? {
            var end = start
            while end < chars.count, end - start < max, chars[end].isASCII, chars[end].isNumber { end += 1 }
            return end > start ? (Int(String(chars[start..<end]))!, end) : nil
        }

        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                let n = chars[i + 1]
                i += 2
                switch n {
                case "n": literal.append("\n")
                case "t": literal.append("\t")
                case "r": literal.append("\r")
                case "U": flush(); pieces.append(.upper)
                case "L": flush(); pieces.append(.lower)
                case "E": flush(); pieces.append(.endCase)
                case "u": flush(); pieces.append(.nextUpper)
                case "l": flush(); pieces.append(.nextLower)
                // A keycap emoji or an accented digit also sorts between "0" and "9".
                case "0"..."9" where n.isASCII: flush(); pieces.append(.group(n.wholeNumberValue ?? 0))
                default: literal.append(n)
                }
            } else if c == "$", i + 1 < chars.count {
                if chars[i + 1] == "&" {
                    flush()
                    pieces.append(.group(0))
                    i += 2
                } else if chars[i + 1] == "{", let close = chars[(i + 2)...].firstIndex(of: "}") {
                    flush()
                    pieces.append(.named(String(chars[(i + 2)..<close])))
                    i = close + 1
                } else if let (_, end) = digits(from: i + 1, max: 2) {
                    flush()
                    pieces.append(.digits(String(chars[(i + 1)..<end])))
                    i = end
                } else {
                    literal.append(c)
                    i += 1
                }
            } else {
                literal.append(c)
                i += 1
            }
        }
        flush()
        return pieces
    }
}

public struct ReplaceAllResult {
    /// The part of the original text that changes: from the first match to the end of the last.
    public var range: NSRange
    /// What that part becomes.
    public var text: String
    public var count: Int
}

extension SearchQuery {
    /// Works out a replace-all as one edit, so it is one undo step however many matches there are.
    /// Nil when nothing matches, and when `isCancelled` says to stop.
    public func replaceAll(
        in string: NSString, range: NSRange? = nil, with replacement: Replacement, isCancelled: () -> Bool = { false }
    ) -> ReplaceAllResult? {
        let output = NSMutableString()
        var first: Int?
        var cursor = 0
        var count = 0
        var cancelled = false
        var options = Self.matching
        options.insert(.reportProgress)
        let range = range ?? NSRange(location: 0, length: string.length)
        // Built as the matches arrive, so millions of them aren't all held at once.
        regex.enumerateMatches(in: string as String, options: options, range: range) { match, _, stop in
            guard let match else {
                if isCancelled() { cancelled = true; stop.pointee = true }
                return
            }
            if first == nil {
                first = match.range.location
                cursor = match.range.location
            }
            output.append(string.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            output.append(replacement.expand(match, in: string))
            cursor = NSMaxRange(match.range)
            count += 1
            if count % 2048 == 0, isCancelled() { cancelled = true; stop.pointee = true }
        }
        guard let first, !cancelled else { return nil }
        return ReplaceAllResult(range: NSRange(location: first, length: cursor - first), text: output as String, count: count)
    }
}
