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

    /// The snippet as it goes into the text: lines after the first get `indent` in front, each
    /// leading tab becomes `unit`, and `$0` is taken out. `caret` is where `$0` was, in UTF-16
    /// units, or the end.
    public static func expand(_ body: String, indent: String, unit: String) -> (text: String, caret: Int) {
        let lines = body.components(separatedBy: "\n").enumerated().map { index, line -> String in
            let tabs = line.prefix { $0 == "\t" }.count
            let rest = String(repeating: unit, count: tabs) + line.dropFirst(tabs)
            return index == 0 || rest.isEmpty ? rest : indent + rest
        }
        var text = lines.joined(separator: "\n")
        guard let mark = text.range(of: "$0") else { return (text, text.utf16.count) }
        let caret = text[..<mark.lowerBound].utf16.count
        text.removeSubrange(mark)
        return (text, caret)
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
