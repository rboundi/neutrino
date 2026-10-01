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
}
