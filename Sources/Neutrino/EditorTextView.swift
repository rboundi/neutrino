import AppKit
import NeutrinoCore

/// The text view: indentation, bracket pairs, commenting and the current-line highlight.
final class EditorTextView: NSTextView {
    var style = EditorStyle.current
    /// Set by the syntax of the document: comment markers and whether tabs are required.
    var lineComment: String?
    var blockComment: [String]?
    var indentWithTabs = false
    var indentAfterColon = false

    private var currentLineRect = NSRect.zero

    private static let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "`": "`"]
    private static let closers: Set<Character> = [")", "]", "}", "\"", "'", "`"]

    /// The text without the copy that `string` makes.
    private var text: NSMutableString {
        textStorage!.mutableString
    }

    private var usesSpaces: Bool {
        style.insertSpaces && !indentWithTabs
    }

    private var indentUnit: String {
        usesSpaces ? String(repeating: " ", count: style.tabWidth) : "\t"
    }

    private func character(at index: Int) -> Character? {
        guard index >= 0, index < text.length, let scalar = Unicode.Scalar(text.character(at: index)) else { return nil }
        return Character(scalar)
    }

    /// Replaces text as one undoable edit.
    func replace(_ range: NSRange, with string: String) {
        guard shouldChangeText(in: range, replacementString: string) else { return }
        textStorage?.replaceCharacters(in: range, with: string)
        didChangeText()
    }

    // MARK: Typing

    override func insertNewline(_ sender: Any?) {
        guard style.autoIndent else { return super.insertNewline(sender) }
        let selection = selectedRange()
        let line = text.lineRange(for: NSRange(location: selection.location, length: 0))
        var end = line.location
        while end < selection.location, let c = character(at: end), c == " " || c == "\t" { end += 1 }
        let indent = text.substring(with: NSRange(location: line.location, length: end - line.location))

        let before = character(at: selection.location - 1)
        let after = character(at: NSMaxRange(selection))
        if let before, let closer = Self.pairs[before], "([{".contains(before) {
            if after == closer {
                // Between a pair: open a line in the middle and push the closer down.
                insertText("\n" + indent + indentUnit + "\n" + indent, replacementRange: selection)
                setSelectedRange(NSRange(location: selection.location + 1 + (indent + indentUnit).utf16.count, length: 0))
                return
            }
            return insertText("\n" + indent + indentUnit, replacementRange: selection)
        }
        if indentAfterColon && before == ":" {
            return insertText("\n" + indent + indentUnit, replacementRange: selection)
        }
        insertText("\n" + indent, replacementRange: selection)
    }

    override func insertTab(_ sender: Any?) {
        let selection = selectedRange()
        if selection.length > 0, text.substring(with: selection).contains("\n") {
            return shiftRight(sender)
        }
        guard usesSpaces else { return super.insertTab(sender) }
        let line = text.lineRange(for: NSRange(location: selection.location, length: 0))
        let column = selection.location - line.location
        let count = style.tabWidth - column % style.tabWidth
        insertText(String(repeating: " ", count: count), replacementRange: selection)
    }

    override func insertBacktab(_ sender: Any?) {
        shiftLeft(sender)
    }

    override func deleteBackward(_ sender: Any?) {
        let selection = selectedRange()
        guard selection.length == 0, selection.location > 0 else { return super.deleteBackward(sender) }

        if style.autoCloseBrackets, let before = character(at: selection.location - 1),
            let closer = Self.pairs[before], character(at: selection.location) == closer {
            return replace(NSRange(location: selection.location - 1, length: 2), with: "")
        }
        if usesSpaces {
            // In the indentation, delete back to the previous tab stop.
            let line = text.lineRange(for: NSRange(location: selection.location, length: 0))
            let column = selection.location - line.location
            let leading = text.substring(with: NSRange(location: line.location, length: column))
            if column > 1, leading.allSatisfy({ $0 == " " }) {
                let count = (column - 1) % style.tabWidth + 1
                return replace(NSRange(location: selection.location - count, length: count), with: "")
            }
        }
        super.deleteBackward(sender)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        // Only keys typed by hand: edits made by the app pass a replacement range.
        guard style.autoCloseBrackets, replacementRange.location == NSNotFound, !hasMarkedText(),
            let typed = string as? String, typed.count == 1, let key = typed.first
        else { return super.insertText(string, replacementRange: replacementRange) }

        let selection = selectedRange()
        let next = character(at: NSMaxRange(selection))
        if selection.length == 0, Self.closers.contains(key), next == key {
            // Typing a closer that is already there steps over it.
            return setSelectedRange(NSRange(location: selection.location + 1, length: 0))
        }
        guard let closer = Self.pairs[key] else {
            return super.insertText(string, replacementRange: replacementRange)
        }
        if selection.length > 0 {
            let inner = text.substring(with: selection)
            replace(selection, with: typed + inner + String(closer))
            return setSelectedRange(NSRange(location: selection.location + 1, length: selection.length))
        }
        let roomAfter = next == nil || next!.isWhitespace || Self.closers.contains(next!)
        var allowed = roomAfter
        if key == closer {
            // Quotes: not after a word ("don't") or right after another quote.
            let previous = character(at: selection.location - 1)
            if let previous, previous.isLetter || previous.isNumber || previous == key || previous == "\\" {
                allowed = false
            }
        }
        guard allowed else { return super.insertText(string, replacementRange: replacementRange) }
        replace(selection, with: typed + String(closer))
        setSelectedRange(NSRange(location: selection.location + 1, length: 0))
    }

    /// Every edit the user makes passes through here: typing, paste, drag and drop, Services.
    /// Keep the text free of CR so line numbers, searches and saving see one kind of line ending.
    override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        // Checked as UTF-16, because "\r\n" is a single Character and never equals "\r".
        if let strings = replacementStrings, strings.contains(where: { $0.utf16.contains(0x0D) }) {
            // Redo the edits without CR, last range first so earlier ranges stay valid.
            for (range, string) in zip(affectedRanges, strings).reversed() {
                insertText(TextCodec.normalized(string), replacementRange: range.rangeValue)
            }
            return false
        }
        return super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
    }

    // MARK: Lines

    /// Rewrites the lines touched by the selection and keeps them selected.
    private func transformLines(_ transform: ([String]) -> [String]) {
        let selection = selectedRange()
        var block = text.lineRange(for: selection)
        let endsWithNewline = block.length > 0 && text.character(at: NSMaxRange(block) - 1) == 0x0A
        if endsWithNewline { block.length -= 1 }
        let lines = text.substring(with: block).components(separatedBy: "\n")
        let result = transform(lines).joined(separator: "\n")
        guard result != text.substring(with: block) else { return }
        replace(block, with: result)
        let length = (result as NSString).length
        if selection.length == 0 {
            let caret = selection.location + length - block.length
            setSelectedRange(NSRange(location: min(max(caret, block.location), block.location + length), length: 0))
        } else {
            setSelectedRange(NSRange(location: block.location, length: length))
        }
    }

    @objc func shiftRight(_ sender: Any?) {
        let unit = indentUnit
        transformLines { $0.map { $0.isEmpty ? $0 : unit + $0 } }
    }

    @objc func shiftLeft(_ sender: Any?) {
        let width = style.tabWidth
        transformLines { lines in
            lines.map { line in
                if line.hasPrefix("\t") { return String(line.dropFirst()) }
                let spaces = line.prefix(width).prefix { $0 == " " }.count
                return String(line.dropFirst(spaces))
            }
        }
    }

    @objc func toggleComment(_ sender: Any?) {
        if let marker = lineComment {
            transformLines { lines in
                let content = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                let commented = !content.isEmpty && content.allSatisfy {
                    $0.trimmingCharacters(in: .whitespaces).hasPrefix(marker)
                }
                let indent = content.map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
                return lines.map { line in
                    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
                    if commented {
                        guard let range = line.range(of: marker) else { return line }
                        var rest = line[range.upperBound...]
                        if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                        return String(line[..<range.lowerBound]) + rest
                    }
                    let split = line.index(line.startIndex, offsetBy: indent)
                    return String(line[..<split]) + marker + " " + line[split...]
                }
            }
        } else if let block = blockComment, block.count == 2 {
            let selection = selectedRange()
            let inner = text.substring(with: selection)
            if inner.hasPrefix(block[0]), inner.hasSuffix(block[1]), inner.count >= block[0].count + block[1].count {
                let stripped = String(inner.dropFirst(block[0].count).dropLast(block[1].count))
                replace(selection, with: stripped)
                setSelectedRange(NSRange(location: selection.location, length: (stripped as NSString).length))
            } else {
                let wrapped = block[0] + inner + block[1]
                replace(selection, with: wrapped)
                setSelectedRange(NSRange(location: selection.location, length: (wrapped as NSString).length))
            }
        } else {
            NSSound.beep()
        }
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleComment(_:)) {
            return lineComment != nil || blockComment != nil
        }
        return super.validateMenuItem(menuItem)
    }

    // MARK: Current line

    /// The line fragment holding the caret, across the full width of the view.
    private func caretLineRect() -> NSRect? {
        guard style.highlightCurrentLine, selectedRange().length == 0,
            let layoutManager
        else { return nil }
        let location = selectedRange().location
        var rect: NSRect
        if location == text.length, layoutManager.extraLineFragmentTextContainer != nil {
            rect = layoutManager.extraLineFragmentRect
        } else {
            guard layoutManager.numberOfGlyphs > 0 else { return nil }
            let glyph = min(layoutManager.glyphIndexForCharacter(at: location), layoutManager.numberOfGlyphs - 1)
            rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        }
        rect.origin.x = 0
        rect.origin.y += textContainerOrigin.y
        rect.size.width = bounds.width
        return rect
    }

    func updateCurrentLine() {
        let rect = caretLineRect() ?? .zero
        guard rect != currentLineRect else { return }
        setNeedsDisplay(currentLineRect)
        setNeedsDisplay(rect)
        currentLineRect = rect
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let line = caretLineRect() else { return }
        currentLineRect = line
        Theme.currentLine.setFill()
        line.intersection(rect).fill(using: .sourceOver)
    }
}

/// Draws spaces, tabs and line breaks when "Show invisible characters" is on.
final class EditorLayoutManager: NSLayoutManager {
    var showsInvisibles = false
    var invisiblesFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard showsInvisibles, let string = textStorage?.mutableString else { return }
        guard let textView = firstTextView, let container = textView.textContainer else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: invisiblesFont, .foregroundColor: Theme.invisibles]
        // Only the part of each line that is on screen: an unwrapped line can be megabytes long.
        let visible = textView.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        enumerateLineFragments(forGlyphRange: glyphsToShow) { fragment, _, _, glyphs, _ in
            let first = self.glyphIndex(for: NSPoint(x: visible.minX, y: fragment.midY), in: container)
            let last = self.glyphIndex(for: NSPoint(x: visible.maxX, y: fragment.midY), in: container)
            let shown = NSIntersectionRange(glyphs, NSRange(location: first, length: max(last - first, 0) + 1))
            guard shown.length > 0 else { return }
            let range = self.characterRange(forGlyphRange: shown, actualGlyphRange: nil)
            for index in range.location..<NSMaxRange(range) {
                let symbol: String
                switch string.character(at: index) {
                case 0x20: symbol = "·"
                case 0x09: symbol = "→"
                case 0x0A: symbol = "¬"
                default: continue
                }
                let position = self.location(forGlyphAt: self.glyphIndexForCharacter(at: index))
                symbol.draw(
                    at: NSPoint(x: origin.x + fragment.minX + position.x, y: origin.y + fragment.minY),
                    withAttributes: attributes)
            }
        }
    }
}

/// Line numbers beside the text. A plain view next to the scroll view rather than a ruler.
final class GutterView: NSView {
    weak var textView: EditorTextView?
    var lineIndex: () -> LineIndex = { LineIndex() }
    var font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    override var isFlipped: Bool { true }

    /// Wide enough for the largest line number, with room to grow before it has to change.
    func width(forLineCount count: Int) -> CGFloat {
        let digits = max(3, String(count).count)
        let digit = ("8" as NSString).size(withAttributes: [.font: font]).width
        return ceil(digit * CGFloat(digits)) + 16
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.background.setFill()
        bounds.fill()
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer,
            let string = textView.textStorage?.mutableString
        else { return }

        let index = lineIndex()
        let visible = textView.visibleRect
        let offset = textView.textContainerOrigin.y - visible.minY
        let caret = textView.selectedRange().location
        let currentLine = index.line(at: caret)
        let normal: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.gutterText]
        let current: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]

        func drawNumber(_ line: Int, at rect: NSRect) {
            let label = String(line + 1) as NSString
            let attributes = line == currentLine ? current : normal
            let size = label.size(withAttributes: attributes)
            // Sit on the same baseline as the text, which uses a larger font.
            let y = rect.minY + offset + (rect.height - size.height) / 2
            label.draw(at: NSPoint(x: bounds.width - size.width - 8, y: y), withAttributes: attributes)
        }

        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        var glyph = glyphs.location
        while glyph < NSMaxRange(glyphs) {
            var fragment = NSRange()
            let rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &fragment)
            let character = layoutManager.characterIndexForGlyph(at: fragment.location)
            // Only the first fragment of a wrapped line gets a number.
            if character == 0 || string.character(at: character - 1) == 0x0A {
                drawNumber(index.line(at: character), at: rect)
            }
            glyph = NSMaxRange(fragment)
        }
        if layoutManager.extraLineFragmentTextContainer != nil {
            let rect = layoutManager.extraLineFragmentRect
            if rect.maxY + offset >= 0 && rect.minY + offset <= bounds.height {
                drawNumber(index.count - 1, at: rect)
            }
        }
    }
}
