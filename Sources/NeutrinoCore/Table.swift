import Foundation

/// Text with one record per line and fields separated by a comma, semicolon, tab or bar.
public struct DelimitedTable {
    public var delimiter: Character
    public var rows: [[String]]
    /// The UTF-16 offset in the text where each row starts.
    public var offsets: [Int]
    /// False when the text had more rows than were asked for.
    public var isComplete: Bool

    /// The separator used on the first line: whichever of the four appears there most, outside
    /// quotes. A comma when none does.
    public static func detectDelimiter(in text: String) -> Character {
        var counts: [Character: Int] = [",": 0, ";": 0, "\t": 0, "|": 0]
        var quoted = false
        for character in text {
            if character == "\"" { quoted.toggle() }
            if !quoted, character == "\n" { break }
            if !quoted, counts[character] != nil { counts[character]! += 1 }
        }
        // In this order, so a tie goes to the more common separator.
        var best: Character = ","
        for candidate in [",", ";", "\t", "|"] as [Character] where counts[candidate]! > counts[best]! { best = candidate }
        return best
    }

    /// Reads the text the way spreadsheets write it: a field may be in double quotes, and then
    /// it can hold the separator, line breaks, and a quote written twice.
    public init(_ text: String, delimiter: Character? = nil, maxRows: Int = .max) {
        let separator = delimiter ?? Self.detectDelimiter(in: text)
        self.delimiter = separator
        var rows: [[String]] = []
        var offsets: [Int] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var fieldStarted = false
        var offset = 0
        var rowStart = 0
        var complete = true
        var characters = text.makeIterator()
        var pending = characters.next()
        func endRow() {
            row.append(field)
            // A line with nothing on it is not a record.
            if row.count > 1 || !field.isEmpty || fieldStarted { rows.append(row); offsets.append(rowStart) }
            row = []
            field = ""
            fieldStarted = false
        }
        while let character = pending {
            pending = characters.next()
            offset += character.utf16.count
            if quoted {
                if character == "\"" {
                    if pending == "\"" {
                        field.append("\"")
                        pending = characters.next()
                        offset += 1
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(character)
                }
            } else if character == "\"", field.isEmpty {
                quoted = true
                fieldStarted = true
            } else if character == separator {
                row.append(field)
                field = ""
                fieldStarted = false
            } else if character == "\n" {
                endRow()
                rowStart = offset
                if rows.count >= maxRows {
                    complete = pending == nil
                    break
                }
            } else {
                field.append(character)
            }
        }
        if rows.count < maxRows { endRow() }
        self.rows = rows
        self.offsets = offsets
        isComplete = complete
    }

    /// The widest row, which is how many columns the table needs.
    public var columnCount: Int { rows.reduce(0) { max($0, $1.count) } }

    private static func cell(_ row: [String], _ index: Int) -> String { index < row.count ? row[index] : "" }

    /// The rows as a Markdown table under a line of titles.
    public static func markdown(titles: [String], rows: [[String]]) -> String {
        func line(_ row: [String]) -> String {
            let cells = titles.indices.map { index in
                cell(row, index).replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
            }
            return "| " + cells.joined(separator: " | ") + " |"
        }
        let rule = "| " + titles.map { _ in "---" }.joined(separator: " | ") + " |"
        return ([line(titles), rule] + rows.map(line)).joined(separator: "\n") + "\n"
    }

    private static let number = try! NSRegularExpression(pattern: "^-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?$")

    /// The rows as a JSON array with one object per row, keyed by the titles in their order.
    /// A field that is written as a JSON number stays a number; every other field is a string.
    public static func json(titles: [String], rows: [[String]]) -> String {
        func quoted(_ text: String) -> String { "\"" + (TextTransform.jsonEscape(text) ?? "") + "\"" }
        let keys = titles.map(quoted)
        let objects = rows.map { row -> String in
            let pairs = keys.indices.map { index -> String in
                let field = cell(row, index)
                let isNumber = number.firstMatch(in: field, range: NSRange(location: 0, length: field.utf16.count)) != nil
                return keys[index] + ": " + (isNumber ? field : quoted(field))
            }
            return "  {" + pairs.joined(separator: ", ") + "}"
        }
        return "[\n" + objects.joined(separator: ",\n") + "\n]\n"
    }

    /// The rows as lines of tab-separated fields, for pasting into a spreadsheet.
    public static func tabSeparated(_ rows: [[String]]) -> String {
        rows.map { row in
            row.map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
                .joined(separator: "\t")
        }.joined(separator: "\n") + "\n"
    }
}

/// Which part of the text is hidden when a block is folded.
public enum Folding {
    private static func isOpener(_ c: unichar) -> Bool { c == 0x28 || c == 0x5B || c == 0x7B }
    private static func isCloser(_ c: unichar) -> Bool { c == 0x29 || c == 0x5D || c == 0x7D }

    /// The columns of indentation of the line starting at `start`, and where its text begins.
    /// Nil for a line with nothing on it.
    private static func indentation(in string: NSString, lineStart start: Int, tabWidth: Int) -> (columns: Int, textStart: Int)? {
        var columns = 0
        var index = start
        while index < string.length {
            let c = string.character(at: index)
            if c == 0x20 { columns += 1 } else if c == 0x09 { columns = (columns / tabWidth + 1) * tabWidth } else { break }
            index += 1
        }
        guard index < string.length, string.character(at: index) != 0x0A else { return nil }
        return (columns, index)
    }

    /// The last character of the line that isn't a space, or nil for a blank line.
    private static func lastCharacter(in string: NSString, line: NSRange) -> Int? {
        var index = NSMaxRange(line) - 1
        while index >= line.location {
            let c = string.character(at: index)
            if c != 0x20, c != 0x09, c != 0x0A { return index }
            index -= 1
        }
        return nil
    }

    /// A quick answer for drawing fold markers: whether the line opens a bracket it doesn't
    /// close, or is followed by a more indented line.
    public static func isFoldable(in string: NSString, lineStart: Int, tabWidth: Int) -> Bool {
        let tab = max(tabWidth, 1)
        let line = string.lineRange(for: NSRange(location: lineStart, length: 0))
        guard let last = lastCharacter(in: string, line: line),
            let own = indentation(in: string, lineStart: line.location, tabWidth: tab)
        else { return false }
        if isOpener(string.character(at: last)), NSMaxRange(line) < string.length { return true }
        var next = NSMaxRange(line)
        while next < string.length {
            if let other = indentation(in: string, lineStart: next, tabWidth: tab) { return other.columns > own.columns }
            next = NSMaxRange(string.lineRange(for: NSRange(location: next, length: 0)))
        }
        return false
    }

    /// The characters to hide when the block starting on this line is folded. For a line that
    /// ends by opening a bracket, everything up to its partner, so `{…}` is left. Otherwise the
    /// more indented lines below it. Nil when there is nothing to fold.
    public static func range(
        in string: NSString, lineStart: Int, tabWidth: Int, isCode: (Int) -> Bool = { _ in true }
    ) -> NSRange? {
        let tab = max(tabWidth, 1)
        let line = string.lineRange(for: NSRange(location: lineStart, length: 0))
        guard let last = lastCharacter(in: string, line: line),
            let own = indentation(in: string, lineStart: line.location, tabWidth: tab)
        else { return nil }

        if isOpener(string.character(at: last)), isCode(last) {
            var depth = 0
            var index = last + 1
            let limit = min(string.length, last + 4_000_000)
            while index < limit {
                let c = string.character(at: index)
                if isOpener(c), isCode(index) {
                    depth += 1
                } else if isCloser(c), isCode(index) {
                    if depth == 0 {
                        // Only worth folding when the partner is on a later line.
                        return index > NSMaxRange(line) - 1 ? NSRange(location: last + 1, length: index - last - 1) : nil
                    }
                    depth -= 1
                }
                index += 1
            }
        }

        var end: Int?
        var next = NSMaxRange(line)
        while next < string.length {
            let other = string.lineRange(for: NSRange(location: next, length: 0))
            if let indent = indentation(in: string, lineStart: next, tabWidth: tab) {
                guard indent.columns > own.columns else { break }
                end = (lastCharacter(in: string, line: other) ?? other.location) + 1
            }
            next = NSMaxRange(other)
        }
        guard let end, end > last + 1 else { return nil }
        return NSRange(location: last + 1, length: end - last - 1)
    }

    /// Every block to hide when the text is folded down to `level`: 1 folds the outermost
    /// blocks, 2 the blocks inside those, and so on.
    public static func ranges(
        in string: NSString, level: Int, tabWidth: Int, isCode: (Int) -> Bool = { _ in true }
    ) -> [NSRange] {
        var result: [NSRange] = []
        // Where the blocks around the current line end.
        var ends: [Int] = []
        var start = 0
        while start < string.length {
            let line = string.lineRange(for: NSRange(location: start, length: 0))
            // A block that ends on this line, as in `} else {`, is no longer around it.
            while let last = ends.last, NSMaxRange(line) > last { ends.removeLast() }
            var next = NSMaxRange(line)
            if let range = range(in: string, lineStart: start, tabWidth: tabWidth, isCode: isCode) {
                if ends.count + 1 >= level {
                    result.append(range)
                    let end = NSMaxRange(range)
                    let closing = string.lineRange(for: NSRange(location: end, length: 0))
                    // The line with the closing bracket may open the next block; the last line
                    // of an indented block can't.
                    let bracket = end < string.length && isCloser(string.character(at: end))
                    next = max(next, bracket ? closing.location : NSMaxRange(closing))
                } else {
                    ends.append(NSMaxRange(range))
                }
            }
            start = next
        }
        return result
    }
}
