import AppKit
import NeutrinoCore

/// The text view: indentation, bracket pairs, multiple cursors, line commands and the
/// current-line highlight.
final class EditorTextView: NSTextView {
    var style = EditorStyle.current {
        didSet {
            if style.scrollPastEnd != oldValue.scrollPastEnd { sizeToFit() }
            guard style.pageGuide != oldValue.pageGuide || style.font != oldValue.font
                || style.indentGuides != oldValue.indentGuides || style.tabWidth != oldValue.tabWidth
            else { return }
            columnWidth = nil
            needsDisplay = true
        }
    }
    /// Width of one character in the editor font, measured when the page guide first needs it.
    private var columnWidth: CGFloat?
    /// Set by the syntax of the document: comment markers and whether tabs are required.
    var lineComment: String?
    var blockComment: [String]?
    var indentWithTabs = false
    var indentAfterColon = false
    /// Whether the document is Markdown, where Return continues a list.
    var isMarkdown = false

    private var currentLineRect = NSRect.zero

    /// Every selection while there is more than one; empty for an ordinary single selection.
    private(set) var cursors: [NSRange] = []
    private var replaying = false
    private var settingCursors = false

    /// Positions of the bracket next to the caret and its partner.
    private var bracketPair: (Int, Int)?
    /// Tells brackets in code from those in strings and comments. Set by the window controller.
    var isCode: (Int) -> Bool = { _ in true }

    private static let partners: [unichar: unichar] = [
        0x28: 0x29, 0x5B: 0x5D, 0x7B: 0x7D, 0x29: 0x28, 0x5D: 0x5B, 0x7D: 0x7B,
    ]

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
        // An edit made outside the cursor replay moves the text under the extra cursors.
        if !replaying, !cursors.isEmpty {
            cursors = []
            needsDisplay = true
        }
        guard shouldChangeText(in: range, replacementString: string) else { return }
        textStorage?.replaceCharacters(in: range, with: string)
        didChangeText()
    }

    /// With "Scroll past the end" on, the view is half a window taller than its text, so the
    /// last line can be brought up to the middle.
    override func setFrameSize(_ newSize: NSSize) {
        var size = newSize
        if style.scrollPastEnd, let layoutManager, let textContainer, let scroll = enclosingScrollView {
            let content = layoutManager.usedRect(for: textContainer).height + 2 * textContainerInset.height
            size.height = max(size.height, content + (scroll.contentSize.height / 2).rounded())
        }
        super.setFrameSize(size)
    }

    // MARK: Typing

    private static let listItem = try! NSRegularExpression(
        pattern: "^([ \\t]*)(?:([-*+])|(\\d+)([.)]))[ \\t]+(\\[[ xX]\\][ \\t]+)?")

    /// In a Markdown list, Return starts the next item; on an empty item it ends the list.
    private func continueList() -> Bool {
        let selection = selectedRange()
        guard selection.length == 0 else { return false }
        let line = text.lineRange(for: NSRange(location: selection.location, length: 0))
        let head = text.substring(with: NSRange(location: line.location, length: selection.location - line.location)) as NSString
        guard let match = Self.listItem.firstMatch(in: head as String, range: NSRange(location: 0, length: head.length))
        else { return false }
        if match.range.length == head.length {
            // Nothing but the marker before the caret. With nothing after it either, drop it.
            let rest = text.substring(with: NSRange(location: selection.location, length: NSMaxRange(line) - selection.location))
            guard rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            replace(NSRange(location: line.location, length: head.length), with: "")
            return true
        }
        var marker = head.substring(with: match.range(at: 1))
        if match.range(at: 2).location != NSNotFound {
            marker += head.substring(with: match.range(at: 2))
        } else {
            let number = Int(head.substring(with: match.range(at: 3))) ?? 0
            marker += "\(number + 1)" + head.substring(with: match.range(at: 4))
        }
        marker += match.range(at: 5).location != NSNotFound ? " [ ] " : " "
        insertText("\n" + marker, replacementRange: selection)
        return true
    }

    override func insertNewline(_ sender: Any?) {
        if isMarkdown, continueList() { return }
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
        if cursors.count > 1, !replaying, replacementRange.location == NSNotFound, !hasMarkedText() {
            return replay { _ in self.insertOne(string, replacementRange: replacementRange) }
        }
        insertOne(string, replacementRange: replacementRange)
    }

    private func insertOne(_ string: Any, replacementRange: NSRange) {
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

    // MARK: Multiple cursors

    private static let cursorLimit = 1000

    var cursorCount: Int { max(cursors.count, 1) }

    /// Sorted, with overlapping and duplicate ranges merged.
    private static func merge(_ ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            if let last = result.last, range.location < NSMaxRange(last) || range == last {
                result[result.count - 1] = NSUnionRange(last, range)
            } else {
                result.append(range)
            }
        }
        return result
    }

    private func setCursors(_ ranges: [NSRange]) {
        var merged = Self.merge(ranges)
        // Every keystroke is replayed once per cursor, so the number has to stay reasonable.
        if merged.count > Self.cursorLimit {
            merged = Array(merged.prefix(Self.cursorLimit))
            NSSound.beep()
        }
        settingCursors = true
        defer {
            settingCursors = false
            needsDisplay = true
        }
        guard merged.count > 1 else {
            cursors = []
            if let only = merged.first { setSelectedRange(only) }
            return
        }
        cursors = merged
        // The system shows the selections; carets without a selection are drawn in draw(_:).
        let selected = merged.filter { $0.length > 0 }
        if selected.isEmpty {
            setSelectedRange(merged[merged.count - 1])
        } else {
            setSelectedRanges(selected.map(NSValue.init(range:)), affinity: .downstream, stillSelecting: false)
        }
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        guard !replaying, !settingCursors else { return }
        // The selection was changed some other way: by the mouse, a menu command or undo.
        if ranges.count > 1 {
            if !stillSelecting { cursors = ranges.map(\.rangeValue) }
        } else if !cursors.isEmpty {
            cursors = []
            needsDisplay = true
        }
    }

    /// Runs an editing or movement command once per cursor, as one undo step.
    private func replay(_ action: (Int) -> Void) {
        replaying = true
        undoManager?.beginUndoGrouping()
        var result: [NSRange] = []
        var shift = 0
        for (index, cursor) in cursors.enumerated() {
            let before = text.length
            let location = min(max(cursor.location + shift, 0), before)
            let range = NSRange(location: location, length: min(cursor.length, before - location))
            super.setSelectedRanges([NSValue(range: range)], affinity: .downstream, stillSelecting: false)
            action(index)
            shift += text.length - before
            result.append(selectedRange())
        }
        undoManager?.endUndoGrouping()
        replaying = false
        setCursors(result)
    }

    override func doCommand(by selector: Selector) {
        guard cursors.count > 1, !replaying else { return super.doCommand(by: selector) }
        if selector == #selector(cancelOperation(_:)) {
            return setCursors([cursors[0]])
        }
        replay { _ in super.doCommand(by: selector) }
    }

    /// Pastes with the block's indentation changed to that of the line the caret is on.
    @objc func pasteAndIndent(_ sender: Any?) {
        guard let pasted = NSPasteboard.general.string(forType: .string) else { return NSSound.beep() }
        let selection = selectedRange()
        let line = text.lineRange(for: NSRange(location: selection.location, length: 0))
        var end = line.location
        while end < NSMaxRange(line), let c = character(at: end), c == " " || c == "\t" { end += 1 }
        let indent = text.substring(with: NSRange(location: line.location, length: end - line.location))
        insertText(PasteIndent.reindent(TextCodec.normalized(pasted), to: indent), replacementRange: selection)
    }

    /// With nothing selected, Copy takes the whole line.
    override func copy(_ sender: Any?) {
        guard selectedRange().length == 0, cursors.isEmpty, text.length > 0 else { return super.copy(sender) }
        let line = text.lineRange(for: selectedRange())
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text.substring(with: line), forType: .string)
    }

    /// With nothing selected, Cut takes the whole line.
    override func cut(_ sender: Any?) {
        guard selectedRange().length == 0, cursors.isEmpty, text.length > 0, isEditable else { return super.cut(sender) }
        let line = text.lineRange(for: selectedRange())
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text.substring(with: line), forType: .string)
        replace(line, with: "")
    }

    /// Control-Option-arrow moves by a part of a name: `camel|Case`, `snake|_case`. With Shift
    /// it selects.
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags.subtracting(.shift) == [.control, .option], let key = event.specialKey,
            key == .leftArrow || key == .rightArrow {
            return moveBySubWord(forward: key == .rightArrow, extend: flags.contains(.shift))
        }
        super.keyDown(with: event)
    }

    private func moveBySubWord(forward: Bool, extend: Bool) {
        let selection = selectedRange()
        var range: NSRange
        if forward {
            let end = SubWord.next(in: text, from: NSMaxRange(selection))
            range = extend ? NSRange(location: selection.location, length: end - selection.location) : NSRange(location: end, length: 0)
        } else {
            let start = SubWord.previous(in: text, from: selection.location)
            range = extend ? NSRange(location: start, length: NSMaxRange(selection) - start) : NSRange(location: start, length: 0)
        }
        setSelectedRange(range)
        scrollRangeToVisible(NSRange(location: forward ? NSMaxRange(range) : range.location, length: 0))
    }

    override func paste(_ sender: Any?) {
        guard cursors.count > 1, let pasted = NSPasteboard.general.string(forType: .string) else {
            return super.paste(sender)
        }
        let clean = TextCodec.normalized(pasted)
        var lines = clean.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        // One copied line per cursor goes to each cursor in turn; anything else goes to all of them.
        let perCursor = lines.count == cursors.count
        replay { index in
            super.insertText(perCursor ? lines[index] : clean, replacementRange: self.selectedRange())
        }
    }

    override func mouseDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        guard flags == .command, event.clickCount == 1 else { return super.mouseDown(with: event) }
        // Command-click adds a caret, or removes the one that is already there.
        let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        var all = cursors.isEmpty ? [selectedRange()] : cursors
        if let existing = all.firstIndex(where: { $0.length == 0 && $0.location == index }), all.count > 1 {
            all.remove(at: existing)
        } else {
            all.append(NSRange(location: index, length: 0))
        }
        setCursors(all)
    }

    /// Selects the word at the caret, then on each further use the next place the same text occurs.
    @objc func selectNextOccurrence(_ sender: Any?) {
        let all = cursors.isEmpty ? [selectedRange()] : cursors
        guard let last = all.last, let first = all.first else { return }
        if all.count == 1, last.length == 0 {
            let word = selectionRange(forProposedRange: last, granularity: .selectByWord)
            if word.length > 0 { setSelectedRange(word) }
            return
        }
        guard last.length > 0 else { return NSSound.beep() }
        let needle = text.substring(with: last)
        let end = NSMaxRange(last)
        var found = text.range(of: needle, options: [], range: NSRange(location: end, length: text.length - end))
        if found.location == NSNotFound {
            found = text.range(of: needle, options: [], range: NSRange(location: 0, length: first.location))
        }
        guard found.location != NSNotFound, !all.contains(found) else { return NSSound.beep() }
        setCursors(all + [found])
        scrollRangeToVisible(found)
    }

    /// Puts a cursor on every place the selected text occurs, or the word at the caret.
    @objc func selectAllOccurrences(_ sender: Any?) {
        var selection = selectedRange()
        let wholeWords = selection.length == 0
        if wholeWords { selection = selectionRange(forProposedRange: selection, granularity: .selectByWord) }
        guard selection.length > 0 else { return NSSound.beep() }
        let needle = text.substring(with: selection)
        var found: [NSRange] = []
        var search = NSRange(location: 0, length: text.length)
        // One more than the limit, so going over it is noticed and reported.
        while found.count <= Self.cursorLimit {
            let hit = text.range(of: needle, options: .literal, range: search)
            guard hit.location != NSNotFound else { break }
            // From a bare caret only whole words count, as with Select Next Occurrence.
            if !wholeWords || selectionRange(forProposedRange: NSRange(location: hit.location, length: 0), granularity: .selectByWord) == hit {
                found.append(hit)
            }
            search = NSRange(location: NSMaxRange(hit), length: text.length - NSMaxRange(hit))
        }
        setCursors(found)
    }

    @objc func addCursorBelow(_ sender: Any?) { addCursor(below: true) }
    @objc func addCursorAbove(_ sender: Any?) { addCursor(below: false) }

    private func addCursor(below: Bool) {
        let all = cursors.isEmpty ? [selectedRange()] : cursors
        guard let from = below ? all.last : all.first else { return }
        let line = text.lineRange(for: NSRange(location: from.location, length: 0))
        let column = from.location - line.location
        let target: NSRange
        if below {
            guard NSMaxRange(line) < text.length || (line.length > 0 && text.character(at: NSMaxRange(line) - 1) == 0x0A)
            else { return NSSound.beep() }
            target = text.lineRange(for: NSRange(location: NSMaxRange(line), length: 0))
        } else {
            guard line.location > 0 else { return NSSound.beep() }
            target = text.lineRange(for: NSRange(location: line.location - 1, length: 0))
        }
        var length = target.length
        if length > 0, text.character(at: NSMaxRange(target) - 1) == 0x0A { length -= 1 }
        let caret = NSRange(location: target.location + min(column, length), length: 0)
        setCursors(all + [caret])
        scrollRangeToVisible(caret)
    }

    // MARK: Expanding the selection

    /// Each step of Expand Selection, so Shrink Selection can go back through them.
    private var expansions: [(from: NSRange, to: NSRange)] = []

    private static func isOpener(_ c: unichar) -> Bool { c == 0x28 || c == 0x5B || c == 0x7B }
    private static func isCloser(_ c: unichar) -> Bool { c == 0x29 || c == 0x5D || c == 0x7D }

    /// The nearest pair of brackets around `range`, skipping those in strings and comments.
    private func enclosingBrackets(of range: NSRange) -> (open: Int, close: Int)? {
        let limit = 200_000
        var depth = 0
        var open: Int?
        var index = range.location - 1
        while index >= 0, range.location - index < limit {
            let c = text.character(at: index)
            if Self.isCloser(c), isCode(index) {
                depth += 1
            } else if Self.isOpener(c), isCode(index) {
                if depth == 0 {
                    open = index
                    break
                }
                depth -= 1
            }
            index -= 1
        }
        guard let open else { return nil }
        depth = 0
        index = NSMaxRange(range)
        while index < text.length, index - NSMaxRange(range) < limit {
            let c = text.character(at: index)
            if Self.isOpener(c), isCode(index) {
                depth += 1
            } else if Self.isCloser(c), isCode(index) {
                if depth == 0 { return (open, index) }
                depth -= 1
            }
            index += 1
        }
        return nil
    }

    /// The nearest pair of the same quote character around `range`, on its line.
    private func enclosingQuotes(of range: NSRange) -> (open: Int, close: Int)? {
        let line = text.lineRange(for: NSRange(location: range.location, length: 0))
        guard NSMaxRange(range) <= NSMaxRange(line) else { return nil }
        var best: (open: Int, close: Int)?
        for quote: unichar in [0x22, 0x27, 0x60] {
            var open = range.location - 1
            while open >= line.location, text.character(at: open) != quote { open -= 1 }
            var close = NSMaxRange(range)
            while close < NSMaxRange(line), text.character(at: close) != quote { close += 1 }
            guard open >= line.location, close < NSMaxRange(line) else { continue }
            if best == nil || close - open < best!.close - best!.open { best = (open, close) }
        }
        return best
    }

    /// Grows the selection to the next larger thing around it: the word, what is inside the
    /// nearest quotes or brackets, those with their quotes or brackets, the line, everything.
    @objc func expandSelection(_ sender: Any?) {
        let selection = selectedRange()
        if let last = expansions.last, last.to != selection { expansions = [] }
        var candidates = [selectionRange(forProposedRange: selection, granularity: .selectByWord)]
        for pair in [enclosingBrackets(of: selection), enclosingQuotes(of: selection)] {
            guard let pair else { continue }
            candidates.append(NSRange(location: pair.open + 1, length: pair.close - pair.open - 1))
            candidates.append(NSRange(location: pair.open, length: pair.close - pair.open + 1))
        }
        let lines = text.lineRange(for: selection)
        var content = lines
        if content.length > 0, text.character(at: NSMaxRange(content) - 1) == 0x0A { content.length -= 1 }
        candidates += [content, lines, NSRange(location: 0, length: text.length)]
        let larger = candidates.filter {
            $0.location <= selection.location && NSMaxRange($0) >= NSMaxRange(selection) && $0.length > selection.length
        }
        guard let next = larger.min(by: { $0.length < $1.length }) else { return NSSound.beep() }
        expansions.append((selection, next))
        setSelectedRange(next)
    }

    /// Goes back one step of Expand Selection.
    @objc func shrinkSelection(_ sender: Any?) {
        guard let last = expansions.last, last.to == selectedRange() else {
            expansions = []
            return NSSound.beep()
        }
        expansions.removeLast()
        setSelectedRange(last.from)
    }

    // MARK: Numbers

    @objc func increaseNumber(_ sender: Any?) { changeNumbers(by: 1) }
    @objc func decreaseNumber(_ sender: Any?) { changeNumbers(by: -1) }

    /// Adds `step` to the whole number at the caret, or at each cursor.
    private func changeNumbers(by step: Int) {
        var changed = false
        if cursors.count > 1 {
            replay { _ in changed = self.changeNumber(by: step) || changed }
        } else {
            changed = changeNumber(by: step)
        }
        if !changed { NSSound.beep() }
    }

    private func changeNumber(by step: Int) -> Bool {
        let selection = selectedRange()
        func isDigit(_ index: Int) -> Bool { (0x30...0x39).contains(text.character(at: index)) }
        var start = selection.location
        var end = NSMaxRange(selection)
        while start > 0, isDigit(start - 1) { start -= 1 }
        while end < text.length, isDigit(end) { end += 1 }
        let digits = text.substring(with: NSRange(location: start, length: end - start))
        guard !digits.isEmpty, digits.count <= 18, let value = Int(digits) else { return false }
        // A minus counts as a sign unless it follows something it could be subtracting from.
        var negative = false
        if start > 0, text.character(at: start - 1) == 0x2D {
            let before = start > 1 ? character(at: start - 2) : nil
            negative = before == nil || !(before!.isLetter || before!.isNumber || before == ")" || before == "]")
        }
        let result = (negative ? -value : value) + step
        var number = String(abs(result))
        // Keep the width of a number written with leading zeros.
        if digits.hasPrefix("0"), digits.count > 1, number.count < digits.count {
            number = String(repeating: "0", count: digits.count - number.count) + number
        }
        if result < 0 { number = "-" + number }
        let whole = NSRange(location: start - (negative ? 1 : 0), length: end - start + (negative ? 1 : 0))
        replace(whole, with: number)
        setSelectedRange(NSRange(location: whole.location + (number as NSString).length, length: 0))
        return true
    }

    /// Types 1, 2, 3… at the cursors, in order.
    @objc func insertNumbers(_ sender: Any?) {
        guard cursors.count > 1 else { return NSSound.beep() }
        replay { index in super.insertText("\(index + 1)", replacementRange: self.selectedRange()) }
    }

    /// Puts a caret at the end of every line of the selection.
    @objc func splitSelectionIntoLines(_ sender: Any?) {
        let selection = selectedRange()
        guard selection.length > 0 else { return NSSound.beep() }
        var carets: [NSRange] = []
        var position = selection.location
        while position <= NSMaxRange(selection) {
            let line = text.lineRange(for: NSRange(location: position, length: 0))
            var end = NSMaxRange(line)
            if line.length > 0, text.character(at: end - 1) == 0x0A { end -= 1 }
            carets.append(NSRange(location: min(end, NSMaxRange(selection)), length: 0))
            if NSMaxRange(line) <= position { break }
            position = NSMaxRange(line)
        }
        setCursors(carets)
    }

    /// The characters in the part of the view that is showing.
    private func visibleCharacters() -> NSRange {
        guard let layoutManager, let textContainer else { return NSRange(location: 0, length: 0) }
        let glyphs = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        return layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    }

    private func caretRect(at index: Int) -> NSRect? {
        guard let layoutManager else { return nil }
        var fragment: NSRect
        var x: CGFloat
        if index >= text.length, layoutManager.extraLineFragmentTextContainer != nil {
            fragment = layoutManager.extraLineFragmentRect
            x = fragment.minX
        } else {
            guard layoutManager.numberOfGlyphs > 0 else { return nil }
            if index >= text.length {
                let glyph = layoutManager.numberOfGlyphs - 1
                fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                x = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil).maxX
            } else {
                let glyph = layoutManager.glyphIndexForCharacter(at: index)
                fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                x = fragment.minX + layoutManager.location(forGlyphAt: glyph).x
            }
        }
        let origin = textContainerOrigin
        return NSRect(x: x + origin.x, y: fragment.minY + origin.y, width: 1.5, height: fragment.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard cursors.count > 1 else { return }
        let system = selectedRange()
        let visible = visibleCharacters()
        insertionPointColor.setFill()
        // Only carets on screen: asking for the position of a distant one would lay out
        // everything up to it.
        for cursor in cursors where cursor.length == 0 && cursor != system
            && cursor.location >= visible.location && cursor.location <= NSMaxRange(visible) {
            caretRect(at: cursor.location)?.fill()
        }
    }

    // MARK: Matching brackets

    /// Finds the bracket beside the caret and its partner, skipping strings and comments.
    func updateBracketMatch() {
        var pair: (Int, Int)?
        let selection = selectedRange()
        if selection.length == 0, cursors.isEmpty {
            for index in [selection.location, selection.location - 1] where index >= 0 && index < text.length {
                if let partner = partner(of: index) {
                    pair = (index, partner)
                    break
                }
            }
        }
        guard pair?.0 != bracketPair?.0 || pair?.1 != bracketPair?.1 else { return }
        bracketPair = pair
        needsDisplay = true
    }

    private func partner(of index: Int) -> Int? {
        let bracket = text.character(at: index)
        guard let other = Self.partners[bracket], isCode(index) else { return nil }
        let forward = bracket < other
        let limit = 100_000
        var depth = 0
        var position = index
        var steps = 0
        while position >= 0, position < text.length, steps < limit {
            let character = text.character(at: position)
            if character == bracket || character == other, isCode(position) {
                depth += character == bracket ? 1 : -1
                if depth == 0 { return position }
            }
            position += forward ? 1 : -1
            steps += 1
        }
        return nil
    }

    @objc func goToMatchingBracket(_ sender: Any?) {
        guard let (_, partner) = bracketPair else { return NSSound.beep() }
        // Land where the partner is beside the caret, so the command also goes back again.
        let closes = [0x29, 0x5D, 0x7D].contains(text.character(at: partner))
        let caret = NSRange(location: partner + (closes ? 1 : 0), length: 0)
        setSelectedRange(caret)
        scrollRangeToVisible(caret)
    }

    private func drawBracketMatch() {
        guard let (first, second) = bracketPair, let layoutManager, let textContainer else { return }
        let visible = visibleCharacters()
        Theme.bracketMatch.setFill()
        for index in [first, second] where index < text.length && NSLocationInRange(index, visible) {
            let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            rect.origin.x += textContainerOrigin.x
            rect.origin.y += textContainerOrigin.y
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        }
    }

    // MARK: Lines

    /// Rewrites the lines touched by the selection and keeps them selected. With `wholeDocument`,
    /// an empty selection means every line.
    private func transformLines(wholeDocument: Bool = false, _ transform: ([String]) -> [String]) {
        var selection = selectedRange()
        if wholeDocument, selection.length == 0 { selection = NSRange(location: 0, length: text.length) }
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

    @objc func duplicateLines(_ sender: Any?) {
        let selection = selectedRange()
        let block = text.lineRange(for: selection)
        let lines = text.substring(with: block)
        let complete = lines.hasSuffix("\n")
        replace(NSRange(location: NSMaxRange(block), length: 0), with: complete ? lines : "\n" + lines)
        setSelectedRange(NSRange(location: selection.location + block.length + (complete ? 0 : 1), length: selection.length))
    }

    @objc func deleteLines(_ sender: Any?) {
        var block = text.lineRange(for: selectedRange())
        // The last line has no line break after it; take the one before it instead.
        if NSMaxRange(block) == text.length, block.location > 0,
            block.length == 0 || text.character(at: NSMaxRange(block) - 1) != 0x0A {
            block = NSRange(location: block.location - 1, length: block.length + 1)
        }
        replace(block, with: "")
    }

    @objc func moveLinesUp(_ sender: Any?) {
        let selection = selectedRange()
        let block = text.lineRange(for: selection)
        guard block.location > 0 else { return NSSound.beep() }
        let previous = text.lineRange(for: NSRange(location: block.location - 1, length: 0))
        var moving = text.substring(with: block)
        var passed = text.substring(with: previous)
        if !moving.hasSuffix("\n") {
            moving += "\n"
            passed.removeLast()
        }
        replace(NSUnionRange(previous, block), with: moving + passed)
        let moved = NSRange(location: selection.location - previous.length, length: selection.length)
        setSelectedRange(moved)
        scrollRangeToVisible(moved)
    }

    @objc func moveLinesDown(_ sender: Any?) {
        let selection = selectedRange()
        let block = text.lineRange(for: selection)
        guard NSMaxRange(block) < text.length else { return NSSound.beep() }
        let next = text.lineRange(for: NSRange(location: NSMaxRange(block), length: 0))
        var moving = text.substring(with: block)
        var passed = text.substring(with: next)
        if !passed.hasSuffix("\n") {
            passed += "\n"
            moving.removeLast()
        }
        replace(NSUnionRange(block, next), with: passed + moving)
        let moved = NSRange(location: selection.location + (passed as NSString).length, length: selection.length)
        setSelectedRange(moved)
        scrollRangeToVisible(moved)
    }

    /// Joins the selected lines, or the current line with the next, with a single space.
    @objc func joinLines(_ sender: Any?) {
        var range = selectedRange()
        if !text.substring(with: range).contains("\n") {
            let line = text.lineRange(for: NSRange(location: range.location, length: 0))
            guard NSMaxRange(line) < text.length else { return NSSound.beep() }
            range = NSUnionRange(line, text.lineRange(for: NSRange(location: NSMaxRange(line), length: 0)))
        }
        var block = text.substring(with: range)
        let trailing = block.hasSuffix("\n")
        if trailing { block.removeLast() }
        let joined = block.replacingOccurrences(of: "[ \\t]*\\n[ \\t]*", with: " ", options: .regularExpression)
        replace(range, with: joined + (trailing ? "\n" : ""))
        setSelectedRange(NSRange(location: range.location, length: (joined as NSString).length))
    }

    @objc func sortLines(_ sender: Any?) {
        transformLines(wholeDocument: true) { $0.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    }

    @objc func removeDuplicateLines(_ sender: Any?) {
        transformLines(wholeDocument: true) { lines in
            var seen = Set<String>()
            return lines.filter { seen.insert($0).inserted }
        }
    }

    @objc func sortLinesByNumber(_ sender: Any?) {
        transformLines(wholeDocument: true, TextTransform.sortedByNumber)
    }

    @objc func reverseLines(_ sender: Any?) {
        transformLines(wholeDocument: true) { $0.reversed() }
    }

    @objc func trimTrailingSpaces(_ sender: Any?) {
        transformLines(wholeDocument: true) { lines in
            lines.map { line in
                var line = line
                while line.last == " " || line.last == "\t" { line.removeLast() }
                return line
            }
        }
    }

    @objc func deleteBlankLines(_ sender: Any?) {
        transformLines(wholeDocument: true) { $0.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
    }

    /// Lines up the selected lines on the first `marker` in each.
    func alignLines(at marker: String) {
        transformLines { TextTransform.align($0, at: marker) }
    }

    /// Wraps the selected lines again, or the paragraph the caret is in, at the page guide
    /// (column 80 without one).
    @objc func rewrapParagraph(_ sender: Any?) {
        let width = style.pageGuide > 0 ? style.pageGuide : 80
        if selectedRange().length == 0 {
            func isBlank(_ range: NSRange) -> Bool {
                text.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            var block = text.lineRange(for: selectedRange())
            guard !isBlank(block) else { return NSSound.beep() }
            while block.location > 0 {
                let previous = text.lineRange(for: NSRange(location: block.location - 1, length: 0))
                if isBlank(previous) { break }
                block = NSUnionRange(previous, block)
            }
            while NSMaxRange(block) < text.length {
                let next = text.lineRange(for: NSRange(location: NSMaxRange(block), length: 0))
                if isBlank(next) || next.length == 0 { break }
                block = NSUnionRange(block, next)
            }
            setSelectedRange(block)
        }
        transformLines { TextTransform.reflow($0.joined(separator: "\n"), width: width).components(separatedBy: "\n") }
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

    // MARK: Completion

    /// Words from the document that start with what is typed, nearest to the caret first.
    override func completions(
        forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>
    ) -> [String]? {
        guard charRange.length > 0, NSMaxRange(charRange) <= text.length else { return [] }
        let typed = text.substring(with: charRange)
        guard let regex = try? NSRegularExpression(
            pattern: "(?<![\\w])" + NSRegularExpression.escapedPattern(for: typed) + "\\w+")
        else { return [] }
        // A million characters either side is plenty, and keeps this quick in a huge file.
        let reach = 1_000_000
        let start = max(charRange.location - reach, 0)
        let window = NSRange(location: start, length: min(NSMaxRange(charRange) + reach, text.length) - start)
        let nearby = text.substring(with: window) as NSString
        let caret = charRange.location - start
        var distance: [String: Int] = [:]
        regex.enumerateMatches(in: nearby as String, range: NSRange(location: 0, length: nearby.length)) { match, _, _ in
            guard let range = match?.range, range.location != caret else { return }
            let word = nearby.substring(with: range)
            distance[word] = min(distance[word] ?? .max, abs(range.location - caret))
        }
        return Array(distance.sorted { ($0.value, $0.key) < ($1.value, $1.key) }.prefix(50).map(\.key))
    }

    // MARK: Transforms

    /// Replaces the selection, or the whole text when nothing is selected, with what `change`
    /// makes of it. Beeps when `change` can't make anything of it.
    private func transformText(_ change: (String) -> String?) {
        let selection = selectedRange()
        let range = selection.length > 0 ? selection : NSRange(location: 0, length: text.length)
        let old = text.substring(with: range)
        guard let new = change(old) else { return NSSound.beep() }
        guard new != old else { return }
        replace(range, with: new)
        if selection.length > 0 {
            setSelectedRange(NSRange(location: range.location, length: (new as NSString).length))
        } else {
            setSelectedRange(NSRange(location: min(selection.location, text.length), length: 0))
        }
    }

    @objc func prettyPrintJSON(_ sender: Any?) {
        let unit = indentUnit
        transformText { TextTransform.json($0, indent: unit) }
    }

    @objc func minifyJSON(_ sender: Any?) { transformText { TextTransform.json($0, indent: nil) } }
    @objc func base64Encode(_ sender: Any?) { transformText(TextTransform.base64Encode) }
    @objc func base64Decode(_ sender: Any?) { transformText(TextTransform.base64Decode) }
    @objc func urlEncode(_ sender: Any?) { transformText(TextTransform.urlEncode) }
    @objc func urlDecode(_ sender: Any?) { transformText(TextTransform.urlDecode) }
    @objc func jsonEscape(_ sender: Any?) { transformText(TextTransform.jsonEscape) }
    @objc func jsonUnescape(_ sender: Any?) { transformText(TextTransform.jsonUnescape) }
    @objc func htmlEncode(_ sender: Any?) { transformText(TextTransform.htmlEncode) }
    @objc func htmlDecode(_ sender: Any?) { transformText(TextTransform.htmlDecode) }
    @objc func zapGremlins(_ sender: Any?) { transformText(Gremlins.zap) }
    @objc func straightenQuotes(_ sender: Any?) { transformText(Gremlins.straightenQuotes) }

    @objc func indentationToSpaces(_ sender: Any?) {
        let width = style.tabWidth
        transformText { Indentation.convert($0, toSpaces: true, width: width) }
    }

    @objc func indentationToTabs(_ sender: Any?) {
        let width = style.tabWidth
        transformText { Indentation.convert($0, toSpaces: false, width: width) }
    }

    /// Typed like any other text, so it goes to every cursor.
    private func type(_ string: String) {
        insertText(string, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    @objc func insertDate(_ sender: Any?) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        type(formatter.string(from: Date()))
    }

    @objc func insertDateAndTime(_ sender: Any?) {
        type(ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime]))
    }

    @objc func insertUUID(_ sender: Any?) {
        type(UUID().uuidString)
    }

    // MARK: Markdown

    @objc func markdownBold(_ sender: Any?) { toggleMark("**") }
    @objc func markdownItalic(_ sender: Any?) { toggleMark("*") }

    /// Puts `mark` around the selection, or takes it away when it is already there, whether
    /// the marks are inside the selection or just outside it.
    private func toggleMark(_ mark: String) {
        let selection = selectedRange()
        let size = (mark as NSString).length
        let inner = text.substring(with: selection) as NSString
        if inner.length >= 2 * size, inner.hasPrefix(mark), inner.hasSuffix(mark) {
            let bare = inner.substring(with: NSRange(location: size, length: inner.length - 2 * size))
            replace(selection, with: bare)
            return setSelectedRange(NSRange(location: selection.location, length: (bare as NSString).length))
        }
        let around = NSRange(location: selection.location - size, length: selection.length + 2 * size)
        if around.location >= 0, NSMaxRange(around) <= text.length,
            text.substring(with: NSRange(location: around.location, length: size)) == mark,
            text.substring(with: NSRange(location: NSMaxRange(selection), length: size)) == mark {
            replace(around, with: inner as String)
            return setSelectedRange(NSRange(location: around.location, length: selection.length))
        }
        replace(selection, with: mark + (inner as String) + mark)
        setSelectedRange(NSRange(location: selection.location + size, length: selection.length))
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleComment(_:)): return lineComment != nil || blockComment != nil
        case #selector(markdownBold(_:)), #selector(markdownItalic(_:)): return isMarkdown && isEditable
        case #selector(insertNumbers(_:)): return cursors.count > 1
        // With nothing selected these take the line, so they are on whenever there is text.
        case #selector(copy(_:)): return text.length > 0
        case #selector(cut(_:)): return text.length > 0 && isEditable
        default: break
        }
        return super.validateMenuItem(menuItem)
    }

    // MARK: Current line

    /// The line fragment holding the caret, across the full width of the view.
    private func caretLineRect() -> NSRect? {
        guard style.highlightCurrentLine, selectedRange().length == 0, cursors.isEmpty,
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

    /// Width of one character in the editor font.
    private func measuredColumnWidth() -> CGFloat {
        let width = columnWidth ?? (" " as NSString).size(withAttributes: [.font: style.font]).width
        columnWidth = width
        return width
    }

    /// A thin vertical line at the start of each level of indentation, on the lines in `rect`.
    /// A blank line takes the levels of the line above it, so the lines run through gaps.
    private func drawIndentGuides(in rect: NSRect) {
        guard style.indentGuides, let layoutManager, let textContainer, text.length > 0 else { return }
        let origin = textContainerOrigin
        let step = measuredColumnWidth() * CGFloat(style.tabWidth)
        let left = origin.x + textContainer.lineFragmentPadding
        let tab = style.tabWidth
        let glyphs = layoutManager.glyphRange(
            forBoundingRect: rect.offsetBy(dx: -origin.x, dy: -origin.y), in: textContainer)
        var levels = 0
        Theme.pageGuide.setFill()
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, range, _ in
            let start = layoutManager.characterIndexForGlyph(at: range.location)
            if start == 0 || self.text.character(at: start - 1) == 0x0A {
                // The first piece of a line: count the columns of its indentation.
                var columns = 0
                var index = start
                var blank = true
                while index < self.text.length {
                    let c = self.text.character(at: index)
                    if c == 0x20 {
                        columns += 1
                    } else if c == 0x09 {
                        columns = (columns / tab + 1) * tab
                    } else {
                        blank = c == 0x0A
                        break
                    }
                    index += 1
                }
                if !blank { levels = columns / tab }
            }
            for level in 0..<levels {
                NSRect(
                    x: (left + CGFloat(level) * step).rounded(), y: fragment.minY + origin.y, width: 1,
                    height: fragment.height
                ).fill(using: .sourceOver)
            }
        }
    }

    /// A thin line after the column chosen in Settings. It lines up with text in a fixed-width font.
    private func drawPageGuide(in rect: NSRect) {
        guard style.pageGuide > 0, let textContainer else { return }
        let width = measuredColumnWidth()
        let x = textContainerOrigin.x + textContainer.lineFragmentPadding + width * CGFloat(style.pageGuide)
        Theme.pageGuide.setFill()
        NSRect(x: x.rounded(), y: rect.minY, width: 1, height: rect.height).fill(using: .sourceOver)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawPageGuide(in: rect)
        drawIndentGuides(in: rect)
        drawBracketMatch()
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
    /// The lines that have a bookmark, counted from 0.
    var bookmarks: () -> Set<Int> = { [] }
    var font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular) {
        didSet { digitWidth = nil }
    }
    /// Width of one digit in `font`, measured once per font.
    private var digitWidth: CGFloat?

    override var isFlipped: Bool { true }

    /// Wide enough for the largest line number, with room to grow before it has to change.
    func width(forLineCount count: Int) -> CGFloat {
        let digits = max(3, String(count).count)
        let digit = digitWidth ?? ("8" as NSString).size(withAttributes: [.font: font]).width
        digitWidth = digit
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

        let marked = bookmarks()
        func drawNumber(_ line: Int, at rect: NSRect) {
            if marked.contains(line) {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: 2, y: rect.midY + offset - 2.5, width: 5, height: 5)).fill()
            }
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
