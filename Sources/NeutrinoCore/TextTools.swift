import Foundation

/// Works out how a file is indented from the text itself.
public enum Indentation {
    /// Tabs or spaces, and how many spaces make one level. Nil when too few lines are indented
    /// to tell; the width is left unset for tabs and when no step between lines stands out.
    public static func detect(in string: NSString, maxLines: Int = 400) -> EditorConfig? {
        var tabLines = 0
        var spaceLines = 0
        var steps: [Int: Int] = [:]
        var previous = 0
        var position = 0
        var seen = 0
        let length = string.length
        while position < length, seen < maxLines {
            let line = string.lineRange(for: NSRange(location: position, length: 0))
            position = NSMaxRange(line)
            var indent = 0
            var index = line.location
            // Leading spaces, read in place: a line can be very long.
            while index < position, string.character(at: index) == 0x20 {
                indent += 1
                index += 1
            }
            guard index < position else { continue }
            let first = string.character(at: index)
            if first == 0x0A || first == 0x0D { continue }
            seen += 1
            if first == 0x09, indent == 0 {
                tabLines += 1
                previous = 0
                continue
            }
            if indent > 0 {
                spaceLines += 1
                let step = indent - previous
                if (2...8).contains(step) { steps[step, default: 0] += 1 }
            }
            previous = indent
        }
        guard tabLines + spaceLines >= 2 else { return nil }
        var config = EditorConfig()
        config.indentWithSpaces = spaceLines >= tabLines
        if config.indentWithSpaces == true {
            // The most common step; the smaller one when two are as common.
            config.indentWidth = steps.max { ($0.value, -$0.key) < ($1.value, -$1.key) }?.key
        }
        return config
    }

    /// Rewrites the indentation of every line with spaces or with tabs. Text after the
    /// indentation is left alone.
    public static func convert(_ text: String, toSpaces: Bool, width: Int) -> String {
        let width = max(width, 1)
        return text.components(separatedBy: "\n").map { line -> String in
            var columns = 0
            var rest = line[...]
            while let first = rest.first, first == " " || first == "\t" {
                columns = first == "\t" ? (columns / width + 1) * width : columns + 1
                rest = rest.dropFirst()
            }
            let indent = toSpaces
                ? String(repeating: " ", count: columns)
                : String(repeating: "\t", count: columns / width) + String(repeating: " ", count: columns % width)
            return indent + rest
        }.joined(separator: "\n")
    }
}

/// Counts for the status bar.
public enum TextStats {
    /// Words in `range`: runs of characters with no white space in them, as `wc` counts.
    public static func words(in string: NSString, range: NSRange) -> Int {
        let end = NSMaxRange(range)
        guard end > range.location else { return 0 }
        let chunk = min(1 << 16, range.length)
        var buffer = [unichar](repeating: 0, count: chunk)
        var position = range.location
        var count = 0
        var inWord = false
        while position < end {
            let length = min(chunk, end - position)
            string.getCharacters(&buffer, range: NSRange(location: position, length: length))
            for i in 0..<length {
                let c = buffer[i]
                let space = c <= 0x20 || c == 0xA0 || c == 0x3000 || (c >= 0x2000 && c <= 0x200B)
                if !space && !inWord { count += 1 }
                inWord = !space
            }
            position += length
        }
        return count
    }
}

/// Changes to the selected text that need nothing but Foundation.
public enum TextTransform {
    /// JSON laid out again, one value per line with `indent` for each level, or on one line when
    /// `indent` is nil. Keys keep their order and numbers their spelling. Nil if it isn't JSON.
    public static func json(_ text: String, indent: String?) -> String? {
        guard let data = text.data(using: .utf8),
            (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
        else { return nil }
        let scalars = Array(text.unicodeScalars)
        var output = String.UnicodeScalarView()
        var depth = 0
        var inString = false
        var escaped = false
        func isSpace(_ scalar: Unicode.Scalar) -> Bool {
            scalar == " " || scalar == "\n" || scalar == "\t" || scalar == "\r"
        }
        func newline() {
            guard let indent else { return }
            output.append("\n")
            for _ in 0..<depth { output.append(contentsOf: indent.unicodeScalars) }
        }
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            i += 1
            if inString {
                output.append(c)
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                continue
            }
            switch c {
            case "\"":
                inString = true
                output.append(c)
            case "{", "[":
                output.append(c)
                var next = i
                while next < scalars.count, isSpace(scalars[next]) { next += 1 }
                if next < scalars.count, scalars[next] == "}" || scalars[next] == "]" {
                    // An empty object or array stays on one line.
                    output.append(scalars[next])
                    i = next + 1
                } else {
                    depth += 1
                    newline()
                }
            case "}", "]":
                depth = max(depth - 1, 0)
                newline()
                output.append(c)
            case ",":
                output.append(c)
                newline()
            case ":":
                output.append(c)
                if indent != nil { output.append(" ") }
            default:
                if !isSpace(c) { output.append(c) }
            }
        }
        return String(output)
    }

    public static func base64Encode(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    /// Nil when the text isn't Base64 or doesn't decode to text.
    public static func base64Decode(_ text: String) -> String? {
        let compact = text.filter { !$0.isWhitespace }
        guard !compact.isEmpty, let data = Data(base64Encoded: compact) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Percent-encodes everything except letters, digits and `-._~`.
    public static func urlEncode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }

    public static func urlDecode(_ text: String) -> String? {
        text.removingPercentEncoding
    }

    /// The text as it would be written inside a JSON string, without the quotes around it.
    public static func jsonEscape(_ text: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
            let quoted = String(data: data, encoding: .utf8), quoted.count >= 2
        else { return nil }
        return String(quoted.dropFirst().dropLast())
    }

    /// The text a JSON string stands for. The quotes around it may be left out.
    public static func jsonUnescape(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let quoted = trimmed.count >= 2 && trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") ? trimmed : "\"" + text + "\""
        // A line break is not allowed inside a JSON string; taking it as one is what is meant.
        let oneLine = quoted.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t")
        guard let data = oneLine.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String
    }

    public static func htmlEncode(_ text: String) -> String {
        var output = ""
        for character in text {
            switch character {
            case "&": output += "&amp;"
            case "<": output += "&lt;"
            case ">": output += "&gt;"
            case "\"": output += "&quot;"
            case "'": output += "&#39;"
            default: output.append(character)
            }
        }
        return output
    }

    private static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{A0}", "copy": "©", "reg": "®",
        "hellip": "…", "mdash": "—", "ndash": "–", "laquo": "«", "raquo": "»", "euro": "€",
    ]

    /// Turns `&amp;`, `&#39;`, `&#x27;` and a few other named entities back into characters.
    /// Anything it doesn't know is left as it is.
    public static func htmlDecode(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z]{2,8});") else { return text }
        let source = text as NSString
        var output = ""
        var position = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let name = source.substring(with: match.range(at: 1))
            var replacement: String?
            if name.hasPrefix("#") {
                let digits = name.dropFirst()
                let value = digits.hasPrefix("x") || digits.hasPrefix("X")
                    ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits, radix: 10)
                replacement = value.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                replacement = entities[name]
            }
            guard let replacement else { continue }
            output += source.substring(with: NSRange(location: position, length: match.range.location - position))
            output += replacement
            position = NSMaxRange(match.range)
        }
        return output + source.substring(from: position)
    }

    /// The first number in a line, for sorting lines by number. Nil when it has none.
    public static func leadingNumber(in line: String) -> Double? {
        guard let range = line.range(of: "-?[0-9]+(\\.[0-9]+)?", options: .regularExpression) else { return nil }
        return Double(line[range])
    }

    /// Lines sorted by the first number in each; lines without a number keep their order at the end.
    public static func sortedByNumber(_ lines: [String]) -> [String] {
        let keyed = lines.enumerated().map { (index: $0.offset, line: $0.element, number: leadingNumber(in: $0.element)) }
        return keyed.sorted { a, b in
            switch (a.number, b.number) {
            case let (x?, y?): return x != y ? x < y : a.index < b.index
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.index < b.index
            }
        }.map(\.line)
    }

    /// Lines padded with spaces so the first `marker` in each sits in the same column.
    /// Lines without it are left alone.
    public static func align(_ lines: [String], at marker: String) -> [String] {
        guard !marker.isEmpty else { return lines }
        let parts = lines.map { line -> (head: String, tail: String)? in
            guard let range = line.range(of: marker) else { return nil }
            var head = String(line[..<range.lowerBound])
            while head.last == " " || head.last == "\t" { head.removeLast() }
            return (head, String(line[range.lowerBound...]))
        }
        let column = parts.compactMap { $0?.head.count }.max() ?? 0
        return zip(lines, parts).map { line, part in
            guard let part else { return line }
            return part.head + String(repeating: " ", count: column - part.head.count + 1) + part.tail
        }
    }

    /// Wraps each paragraph again so no line is longer than `width`. Paragraphs are separated by
    /// blank lines. The indentation and comment marker of a paragraph's first line (`//`, `#`,
    /// `*`, `>`, `--`, `;`) are kept in front of every line of it.
    public static func reflow(_ text: String, width: Int) -> String {
        var output: [String] = []
        var paragraph: [String] = []
        func flush() {
            guard let first = paragraph.first else { return }
            let prefix = first.range(of: "^[ \\t]*(?:(?://+|#+|\\*|>+|--|;+)[ \\t]*)?", options: .regularExpression)
                .map { String(first[$0]) } ?? ""
            let marker = prefix.trimmingCharacters(in: .whitespaces)
            var words: [Substring] = []
            for line in paragraph {
                var body = line[...]
                if body.hasPrefix(prefix) {
                    body = body.dropFirst(prefix.count)
                } else {
                    // A line with less space after the marker, or none of it.
                    body = body.drop { $0 == " " || $0 == "\t" }
                    if !marker.isEmpty, body.hasPrefix(marker) { body = body.dropFirst(marker.count) }
                }
                words += body.split(whereSeparator: { $0 == " " || $0 == "\t" })
            }
            let room = max(width - prefix.count, 20)
            var line = ""
            for word in words {
                if !line.isEmpty, line.count + 1 + word.count > room {
                    output.append(prefix + line)
                    line = ""
                }
                line += (line.isEmpty ? "" : " ") + word
            }
            output.append(line.isEmpty ? String(prefix.reversed().drop { $0 == " " || $0 == "\t" }.reversed()) : prefix + line)
            paragraph = []
        }
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
                output.append(line)
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return output.joined(separator: "\n")
    }
}
