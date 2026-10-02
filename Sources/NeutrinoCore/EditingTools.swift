import Foundation

/// Where the caret is in a JSON document, such as `items[3].name`.
public enum JSONPath {
    private struct Frame {
        var isArray: Bool
        var index = 0
        var key: String?
        var expectsKey = true
    }

    /// The path to the value at `caret`. Nil at the top level, and beyond `limit` characters,
    /// since the text is read from its start every time.
    public static func path(in string: NSString, at caret: Int, limit: Int = 500_000) -> String? {
        guard caret > 0, caret <= limit, caret <= string.length else { return nil }
        // A little past the caret, so a key the caret is inside is read to its end.
        let count = min(caret + 300, string.length)
        var buffer = [unichar](repeating: 0, count: count)
        string.getCharacters(&buffer, range: NSRange(location: 0, length: count))
        var stack: [Frame] = []
        var i = 0
        while i < caret {
            switch buffer[i] {
            case 0x22:  // "
                let start = i + 1
                var end = start
                while end < count, buffer[end] != 0x22 {
                    if buffer[end] == 0x5C { end += 1 }
                    end += 1
                }
                end = min(end, count)
                if let top = stack.last, !top.isArray, top.expectsKey {
                    stack[stack.count - 1].key = String(utf16CodeUnits: Array(buffer[start..<end]), count: end - start)
                    stack[stack.count - 1].expectsKey = false
                }
                i = end + 1
                continue
            case 0x7B: stack.append(Frame(isArray: false))
            case 0x5B: stack.append(Frame(isArray: true))
            case 0x7D, 0x5D: if !stack.isEmpty { stack.removeLast() }
            case 0x2C:
                guard let top = stack.last else { break }
                if top.isArray {
                    stack[stack.count - 1].index += 1
                } else {
                    stack[stack.count - 1].key = nil
                    stack[stack.count - 1].expectsKey = true
                }
            default: break
            }
            i += 1
        }
        var path = ""
        for frame in stack {
            if frame.isArray {
                path += "[\(frame.index)]"
            } else if let key = frame.key {
                if key.range(of: "^[A-Za-z_$][A-Za-z0-9_$]*$", options: .regularExpression) != nil {
                    path += (path.isEmpty ? "" : ".") + key
                } else {
                    path += "[\"\(key)\"]"
                }
            }
        }
        return path.isEmpty ? nil : path
    }
}

/// Abbreviations that Tab expands, read from one text file.
public enum Snippets {
    /// A line `=== name` starts a snippet; the lines up to the next such line are its text.
    /// Anything before the first one is ignored, so the file can explain itself.
    public static func parse(_ text: String) -> [String: String] {
        var snippets: [String: String] = [:]
        var name: String?
        var body: [String] = []
        func finish() {
            guard let name else { return }
            while body.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { body.removeLast() }
            if !body.isEmpty { snippets[name] = body.joined(separator: "\n") }
        }
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("===") {
                finish()
                name = line.dropFirst(3).split(separator: " ").first.map(String.init)
                body = []
            } else if name != nil {
                body.append(line)
            }
        }
        finish()
        return snippets
    }

    private static let stop = try! NSRegularExpression(pattern: "\\$(?:([0-9])|\\{([0-9]):([^}]*)\\})")

    /// The snippet as it goes into the text: lines after the first get `indent` in front and
    /// each leading tab becomes `unit`. `$1`, `$2`… and `$0` are taken out and `${1:name}`
    /// leaves `name`; `stops` says where they were, in UTF-16 units, in the order Tab visits
    /// them: 1 to 9, then 0.
    public static func expand(_ body: String, indent: String, unit: String) -> (text: String, stops: [NSRange]) {
        let lines = body.components(separatedBy: "\n").enumerated().map { index, line -> String in
            let tabs = line.prefix { $0 == "\t" }.count
            let rest = String(repeating: unit, count: tabs) + line.dropFirst(tabs)
            return index == 0 || rest.isEmpty ? rest : indent + rest
        }
        let source = lines.joined(separator: "\n") as NSString
        let output = NSMutableString()
        var found: [(number: Int, range: NSRange)] = []
        var cursor = 0
        for match in stop.matches(in: source as String, range: NSRange(location: 0, length: source.length)) {
            output.append(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            cursor = NSMaxRange(match.range)
            let simple = match.range(at: 1).location != NSNotFound
            let number = Int(source.substring(with: match.range(at: simple ? 1 : 2))) ?? 0
            let filler = simple ? "" : source.substring(with: match.range(at: 3))
            found.append((number, NSRange(location: output.length, length: (filler as NSString).length)))
            output.append(filler)
        }
        output.append(source.substring(from: cursor))
        // 0 is the last stop; the rest go by number, and by place when a number is used twice.
        let ordered = found.enumerated().sorted { a, b in
            let (x, y) = (a.element.number == 0 ? 10 : a.element.number, b.element.number == 0 ? 10 : b.element.number)
            return x != y ? x < y : a.offset < b.offset
        }
        return (output as String, ordered.map(\.element.range))
    }
}

/// The ways of writing a name made of several words.
public enum NameStyle {
    /// The words of a name such as `maxLineCount`, `max_line_count` or `HTTPServer`, in lower case.
    public static func words(of name: String) -> [String] {
        var words: [String] = []
        for chunk in name.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " }) {
            let chars = Array(chunk)
            var start = 0
            for i in 1..<max(chars.count, 1) {
                let lowerThenUpper = !chars[i - 1].isUppercase && chars[i].isUppercase
                // In "HTTPServer" the last capital belongs to "Server".
                let endOfCapitals = chars[i - 1].isUppercase && chars[i].isUppercase && i + 1 < chars.count
                    && chars[i + 1].isLowercase
                if lowerThenUpper || endOfCapitals {
                    words.append(String(chars[start..<i]).lowercased())
                    start = i
                }
            }
            words.append(String(chars[start...]).lowercased())
        }
        return words
    }

    /// The name in the next style: camelCase, snake_case, kebab-case, CONSTANT_CASE, and round
    /// again. Nil for a name of one word, which looks the same in all of them but the last.
    public static func next(_ name: String) -> String? {
        let words = words(of: name)
        guard words.count > 1 else { return nil }
        if name.contains("-") { return words.joined(separator: "_").uppercased() }
        if name.contains("_") {
            if name == name.uppercased() {
                return words[0] + words.dropFirst().map(\.capitalized).joined()
            }
            return words.joined(separator: "-")
        }
        return words.joined(separator: "_")
    }
}

/// Finding the tags of HTML and XML.
public enum HTMLTags {
    private static let tag = try! NSRegularExpression(
        pattern: "<(/?)([A-Za-z][A-Za-z0-9:._-]*)(?:\"[^\"]*\"|'[^']*'|[^<>\"'])*?(/?)>")
    private static let void: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr",
    ]

    private struct Tag {
        var name: String
        var range: NSRange
        var closes: Bool
    }

    /// The tags in `window` that open or close something: not `<br>` and not `<a/>`.
    private static func tags(in string: NSString, window: NSRange) -> [Tag] {
        // Only the window is handed to the regex; the whole of a mutable text would be copied.
        let slice = string.substring(with: window) as NSString
        return tag.matches(in: slice as String, range: NSRange(location: 0, length: slice.length)).compactMap { match in
            let name = slice.substring(with: match.range(at: 2))
            guard match.range(at: 3).length == 0, !void.contains(name.lowercased()) else { return nil }
            let range = NSRange(location: match.range.location + window.location, length: match.range.length)
            return Tag(name: name, range: range, closes: match.range(at: 1).length > 0)
        }
    }

    /// The name of the innermost tag that is open at `caret`, for closing it.
    public static func unclosed(in string: NSString, before caret: Int, limit: Int = 500_000) -> String? {
        let caret = min(max(caret, 0), string.length)
        let start = max(caret - limit, 0)
        var open: [String] = []
        for tag in tags(in: string, window: NSRange(location: start, length: caret - start)) {
            if !tag.closes {
                open.append(tag.name)
            } else if let index = open.lastIndex(of: tag.name) {
                open.removeSubrange(index...)
            }
        }
        return open.last
    }

    /// The tag that closes or opens the one the caret is in.
    public static func partner(in string: NSString, at caret: Int, limit: Int = 1_000_000) -> NSRange? {
        let start = max(caret - limit, 0)
        let end = min(caret + limit, string.length)
        guard end > start else { return nil }
        let all = tags(in: string, window: NSRange(location: start, length: end - start))
        guard let own = all.firstIndex(where: { $0.range.location <= caret && caret <= NSMaxRange($0.range) })
        else { return nil }
        var depth = 0
        let order = all[own].closes ? Array(all[..<own].reversed()) : Array(all[(own + 1)...])
        for other in order where other.name == all[own].name {
            if other.closes == all[own].closes {
                depth += 1
            } else if depth == 0 {
                return other.range
            } else {
                depth -= 1
            }
        }
        return nil
    }
}

/// Tidying a Markdown table.
public enum MarkdownTable {
    private static func cells(of line: String) -> [String] {
        var body = line.trimmingCharacters(in: .whitespaces)[...]
        if body.hasPrefix("|") { body = body.dropFirst() }
        if body.hasSuffix("|"), !body.hasSuffix("\\|") { body = body.dropLast() }
        var cells: [String] = []
        var cell = ""
        var escaped = false
        for character in body {
            if character == "|", !escaped {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            } else {
                cell.append(character)
            }
            escaped = character == "\\" && !escaped
        }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        return cells
    }

    /// The rows with their pipes lined up. Nil when the lines aren't a table.
    public static func format(_ lines: [String]) -> [String]? {
        guard lines.count >= 2, lines.allSatisfy({ $0.contains("|") }) else { return nil }
        let indent = String(lines[0].prefix { $0 == " " || $0 == "\t" })
        let rows = lines.map(cells)
        let columns = rows.map(\.count).max() ?? 0
        func isRule(_ row: [String]) -> Bool {
            row.allSatisfy { $0.range(of: "^:?-+:?$", options: .regularExpression) != nil }
        }
        var widths = [Int](repeating: 3, count: columns)
        for row in rows where !isRule(row) {
            for (index, cell) in row.enumerated() { widths[index] = max(widths[index], cell.count) }
        }
        return rows.map { row in
            let rule = isRule(row)
            let padded = (0..<columns).map { index -> String in
                let cell = index < row.count ? row[index] : (rule ? "---" : "")
                if rule {
                    let dashes = String(repeating: "-", count: widths[index] - (cell.hasPrefix(":") ? 1 : 0) - (cell.hasSuffix(":") ? 1 : 0))
                    return (cell.hasPrefix(":") ? ":" : "") + dashes + (cell.hasSuffix(":") ? ":" : "")
                }
                return cell + String(repeating: " ", count: widths[index] - cell.count)
            }
            return indent + "| " + padded.joined(separator: " | ") + " |"
        }
    }

    /// The line with its task box ticked or cleared; a line without one gets an empty box.
    public static func toggleCheckbox(_ line: String) -> String {
        if let box = line.range(of: "^[ \\t]*(?:[-*+]|[0-9]+[.)])[ \\t]+\\[[ xX]\\]", options: .regularExpression) {
            let mark = line.index(box.upperBound, offsetBy: -2)
            return line.replacingCharacters(in: mark...mark, with: line[mark] == " " ? "x" : " ")
        }
        if let item = line.range(of: "^[ \\t]*(?:[-*+]|[0-9]+[.)])[ \\t]+", options: .regularExpression) {
            return line.replacingCharacters(in: item.upperBound..<item.upperBound, with: "[ ] ")
        }
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        return indent + "- [ ] " + line.dropFirst(indent.count)
    }
}

/// Small conversions of the selected text.
public enum Convert {
    private static func formatter(_ options: ISO8601DateFormatter.Options) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = options
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }

    /// A Unix timestamp, in seconds or milliseconds, as a date in UTC; a date as a timestamp
    /// in seconds. Nil for anything else.
    public static func timestamp(_ text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.range(of: "^[0-9]{1,13}$", options: .regularExpression) != nil, let number = Double(text) {
            // From 12 digits on it can only be milliseconds: in seconds that is the year 5138.
            let seconds = text.count >= 12 ? number / 1000 : number
            return formatter([.withInternetDateTime]).string(from: Date(timeIntervalSince1970: seconds))
        }
        func seconds(_ date: Date) -> String { String(Int(date.timeIntervalSince1970.rounded(.down))) }
        // A date alone is the start of that day; the formatter would also take one with a time
        // after it and drop the time.
        if text.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil {
            return formatter([.withFullDate]).date(from: text).map(seconds)
        }
        // "2026-10-02 08:05:15" is taken as UTC, like a timestamp.
        let spaced = text.replacingOccurrences(of: " ", with: "T")
        for candidate in [spaced, spaced + "Z"] {
            for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
                if let date = formatter(options).date(from: candidate) { return seconds(date) }
            }
        }
        return nil
    }

    /// `0x1F` or `1f` as `31`; `31` as `0x1F`.
    public static func hex(_ text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.range(of: "^[0-9]+$", options: .regularExpression) != nil {
            return UInt64(text).map { "0x" + String($0, radix: 16, uppercase: true) }
        }
        let digits = text.hasPrefix("0x") || text.hasPrefix("0X") ? String(text.dropFirst(2)) : text
        guard digits.range(of: "^[0-9a-fA-F]+$", options: .regularExpression) != nil else { return nil }
        return UInt64(digits, radix: 16).map { String($0) }
    }

    /// JSON with the keys of every object in alphabetical order, laid out with `indent`.
    public static func sortedJSON(_ text: String, indent: String) -> String? {
        guard let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
            let sorted = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]),
            let compact = String(data: sorted, encoding: .utf8)
        else { return nil }
        return TextTransform.json(compact, indent: indent)
    }
}

/// Arithmetic on the selected text: `+ - * / % ^`, brackets, `sqrt` and a few more.
public enum Calculator {
    /// Nil when the text isn't an expression, or its value isn't a number (`1/0`).
    public static func evaluate(_ text: String) -> Double? {
        var parser = Parser(Array(text.unicodeScalars))
        guard let value = parser.expression(), parser.atEnd, value.isFinite else { return nil }
        return value
    }

    /// A whole number without a decimal point; anything else to twelve significant digits.
    public static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(format: "%.12g", value)
    }

    private struct Parser {
        let scalars: [Unicode.Scalar]
        var position = 0
        var depth = 0

        init(_ scalars: [Unicode.Scalar]) { self.scalars = scalars }

        mutating func skipSpaces() {
            while position < scalars.count, scalars[position].properties.isWhitespace { position += 1 }
        }

        var atEnd: Bool {
            mutating get {
                skipSpaces()
                return position == scalars.count
            }
        }

        mutating func take(_ options: String) -> Unicode.Scalar? {
            skipSpaces()
            guard position < scalars.count, options.unicodeScalars.contains(scalars[position]) else { return nil }
            position += 1
            return scalars[position - 1]
        }

        mutating func expression() -> Double? {
            guard var value = term() else { return nil }
            while let sign = take("+-") {
                guard let next = term() else { return nil }
                value = sign == "+" ? value + next : value - next
            }
            return value
        }

        mutating func term() -> Double? {
            guard var value = unary() else { return nil }
            while let sign = take("*/%×÷") {
                guard let next = unary() else { return nil }
                switch sign {
                case "*", "×": value *= next
                case "%": value = value.truncatingRemainder(dividingBy: next)
                default: value /= next
                }
            }
            return value
        }

        mutating func unary() -> Double? {
            // Nesting is bounded, so a long run of minus signs or brackets can't overflow the stack.
            depth += 1
            defer { depth -= 1 }
            guard depth < 200 else { return nil }
            if let sign = take("+-") {
                guard let value = unary() else { return nil }
                return sign == "-" ? -value : value
            }
            guard let base = primary() else { return nil }
            if take("^") != nil {
                guard let exponent = unary() else { return nil }
                return pow(base, exponent)
            }
            return base
        }

        mutating func primary() -> Double? {
            if take("(") != nil {
                guard let value = expression(), take(")") != nil else { return nil }
                return value
            }
            skipSpaces()
            let start = position
            func isDigit(_ s: Unicode.Scalar) -> Bool { s.value >= 0x30 && s.value <= 0x39 }
            func isLetter(_ s: Unicode.Scalar) -> Bool { (s.value | 0x20) >= 0x61 && (s.value | 0x20) <= 0x7A }
            guard position < scalars.count else { return nil }
            if isLetter(scalars[position]) {
                while position < scalars.count, isLetter(scalars[position]) || isDigit(scalars[position]) { position += 1 }
                let name = String(String.UnicodeScalarView(scalars[start..<position])).lowercased()
                switch name {
                case "pi": return Double.pi
                case "e": return M_E
                default: break
                }
                guard take("(") != nil, let argument = expression(), take(")") != nil else { return nil }
                switch name {
                case "sqrt": return argument.squareRoot()
                case "abs": return abs(argument)
                case "round": return argument.rounded()
                case "floor": return argument.rounded(.down)
                case "ceil": return argument.rounded(.up)
                case "ln": return log(argument)
                case "log": return log10(argument)
                default: return nil
                }
            }
            // 0x1F and 0b101.
            if position + 1 < scalars.count, scalars[position] == "0", "xXbB".unicodeScalars.contains(scalars[position + 1]) {
                let radix = (scalars[position + 1].value | 0x20) == 0x78 ? 16 : 2
                position += 2
                let digits = position
                while position < scalars.count, isDigit(scalars[position]) || isLetter(scalars[position]) { position += 1 }
                return UInt64(String(String.UnicodeScalarView(scalars[digits..<position])), radix: radix).map { Double($0) }
            }
            while position < scalars.count, isDigit(scalars[position]) || scalars[position] == "." || scalars[position] == "_" {
                position += 1
            }
            // An exponent, when digits follow it: 1e6, 2.5e-3.
            if position < scalars.count, position > start, (scalars[position].value | 0x20) == 0x65 {
                var end = position + 1
                if end < scalars.count, scalars[end] == "+" || scalars[end] == "-" { end += 1 }
                if end < scalars.count, isDigit(scalars[end]) {
                    while end < scalars.count, isDigit(scalars[end]) { end += 1 }
                    position = end
                }
            }
            guard position > start else { return nil }
            return Double(String(String.UnicodeScalarView(scalars[start..<position])).replacingOccurrences(of: "_", with: ""))
        }
    }
}
