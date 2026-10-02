import AppKit
import NeutrinoCore

/// Find and replace for one editor window.
extension EditorWindowController: FindBarDelegate {
    /// Most rows the Find All list shows; the count in its title is always the full number.
    private static let resultLimit = 5000

    private var findPasteboard: NSPasteboard { NSPasteboard(name: .find) }

    /// Other editors, in window order after this one, for searches across open documents.
    private var otherEditors: [EditorWindowController] {
        let editors = NSDocumentController.shared.documents.compactMap { ($0 as? Document)?.editor }
        guard let own = editors.firstIndex(where: { $0 === self }) else { return editors }
        return Array(editors[(own + 1)...] + editors[..<own])
    }

    private var query: SearchQuery? {
        let pattern = findBar.pattern
        let options = findBar.options
        if let compiledQuery, compiledQuery.pattern == pattern, compiledQuery.options == options {
            return compiledQuery.query
        }
        let query = try? SearchQuery(pattern: pattern, options: options)
        compiledQuery = (pattern, options, query)
        return query
    }

    private var replacement: Replacement {
        Replacement(template: findBar.replacement, isRegex: findBar.options.regex)
    }

    /// The part of the text the search covers.
    private var searchRange: NSRange {
        let whole = NSRange(location: 0, length: text.length)
        guard findBar.scope == .selection, let scope = selectionScope else { return whole }
        return NSIntersectionRange(scope, whole)
    }

    // MARK: Menu commands

    /// Opens the find bar set to search every open document.
    @objc func showFindInDocuments(_ sender: Any?) {
        if isShowingTable { toggleTable(nil) }
        showFind(sender)
        findBar.scope = .allDocuments
        selectionScope = nil
        refreshMatches()
    }

    @objc func keepMatchingLines(_ sender: Any?) { filterLines(keep: true) }
    @objc func deleteMatchingLines(_ sender: Any?) { filterLines(keep: false) }

    /// Keeps only the lines a match of the search touches, or takes those lines out, in the
    /// document or the selection. One undo step.
    private func filterLines(keep: Bool) {
        guard textView.isEditable, ensureMatches() else { return NSSound.beep() }
        // Without a match, Keep would empty the text and Delete would do nothing.
        guard !matches.isEmpty else {
            findMessage = "No matches"
            NSSound.beep()
            return updateFindStatus()
        }
        let scope = text.lineRange(for: searchRange)
        let end = NSMaxRange(scope)
        let result = NSMutableString()
        var removed = 0
        var index = Self.firstIndex(in: matches, endingAfter: scope.location - 1) { $0 }
        var position = scope.location
        while position < end {
            let line = text.lineRange(for: NSRange(location: position, length: 0))
            // Past the matches that end before this line. One that runs over several lines
            // counts for each of them.
            while index < matches.count, NSMaxRange(matches[index]) <= line.location,
                matches[index].location < line.location || matches[index].length > 0 {
                index += 1
            }
            let matched = index < matches.count && matches[index].location < NSMaxRange(line)
            if matched == keep { result.append(text.substring(with: line)) } else { removed += 1 }
            position = NSMaxRange(line)
        }
        guard removed > 0 else {
            findMessage = "No lines to remove"
            return updateFindStatus()
        }
        // When the last line goes, the line break before it goes with it.
        if end == text.length, result.length > 0, text.character(at: end - 1) != 0x0A,
            result.character(at: result.length - 1) == 0x0A {
            result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
        }
        textView.replace(scope, with: result as String)
        textView.setSelectedRange(NSRange(location: scope.location, length: 0))
        findMessage = "Removed \(removed) line\(removed == 1 ? "" : "s")"
        if findBar.isHidden { statusBar.setPosition(findMessage ?? "") } else { updateFindStatus() }
    }

    @objc func showFind(_ sender: Any?) {
        // A table has its own field, which keeps the rows that contain what is typed.
        if isShowingTable { return focusTableFilter() }
        findBar.syncOptions()
        let selection = textView.selectedRange()
        let selected = selection.length > 0 ? text.substring(with: selection) : ""
        if selected.contains("\n") {
            // Several lines selected: search inside them.
            selectionScope = selection
            findBar.scope = .selection
        } else {
            if findBar.scope == .selection { findBar.scope = .document }
            if !selected.isEmpty {
                setPattern(literal: selected)
            } else {
                syncFindPasteboard()
            }
        }
        findBar.isHidden = false
        window?.makeFirstResponder(findBar.findField)
        findBar.findField.selectText(nil)
        findMessage = nil
        refreshMatches()
    }

    @objc func findNext(_ sender: Any?) { findBarNext(backwards: false) }
    @objc func findPrevious(_ sender: Any?) { findBarNext(backwards: true) }
    @objc func findAll(_ sender: Any?) { findBarFindAll() }

    @objc func useSelectionForFind(_ sender: Any?) {
        let selection = textView.selectedRange()
        guard selection.length > 0 else { return NSSound.beep() }
        setPattern(literal: text.substring(with: selection))
        refreshMatches()
    }

    private func setPattern(literal: String) {
        findBar.syncOptions()
        findBar.pattern = findBar.options.regex ? NSRegularExpression.escapedPattern(for: literal) : literal
        writeFindPasteboard()
    }

    private func writeFindPasteboard() {
        guard !findBar.pattern.isEmpty else { return }
        findPasteboard.clearContents()
        findPasteboard.setString(findBar.pattern, forType: .string)
    }

    /// Picks up the search string from another window or another app.
    func syncFindPasteboard() {
        guard let shared = findPasteboard.string(forType: .string), shared != findBar.pattern else { return }
        findBar.pattern = shared
        if !findBar.isHidden {
            findBar.syncOptions()
            refreshMatches()
        }
    }

    // MARK: Matches

    /// Searches in the background and updates the highlights and the count.
    func refreshMatches() {
        let generation = findGeneration.next()
        matchesAreCurrent = false
        guard !findBar.isHidden else {
            if !matches.isEmpty {
                matches = []
                decorateVisible(force: true)
            }
            return
        }
        guard let query else {
            matches = []
            matchesAreCurrent = true
            decorateVisible(force: true)
            return findBar.setStatus(findBar.pattern.isEmpty ? "" : "Invalid regular expression", isError: true)
        }
        let range = searchRange
        after(text.length > Self.debounceLimit ? 0.25 : 0) { [weak self] in
            guard let self, self.findGeneration.isCurrent(generation) else { return }
            guard let doc = self.doc else { return }
            let snapshot = Unchecked(value: doc.snapshotText())
            self.workQueue.async {
                let found = query.ranges(in: snapshot.value, range: range) { !self.findGeneration.isCurrent(generation) }
                DispatchQueue.main.async {
                    guard self.findGeneration.isCurrent(generation) else { return }
                    self.matches = found
                    self.matchesAreCurrent = true
                    self.decorateVisible(force: true)
                    self.updateFindStatus()
                }
            }
        }
    }

    /// Makes sure `matches` reflects the text right now, searching on the spot if needed.
    @discardableResult
    private func ensureMatches() -> Bool {
        guard let query else { return false }
        if !matchesAreCurrent {
            _ = findGeneration.next()
            matches = query.ranges(in: text, range: searchRange)
            matchesAreCurrent = true
            if !findBar.isHidden { decorateVisible(force: true) }
        }
        return true
    }

    func updateFindStatus() {
        if let findMessage { return findBar.setStatus(findMessage) }
        guard matchesAreCurrent, query != nil else { return }
        guard !matches.isEmpty else { return findBar.setStatus("No matches") }
        let selection = textView.selectedRange()
        let index = Self.firstIndex(in: matches, endingAfter: selection.location - 1) { $0 }
        if index < matches.count, matches[index] == selection {
            findBar.setStatus("\(index + 1) of \(matches.count)")
        } else {
            findBar.setStatus(matches.count == 1 ? "1 match" : "\(matches.count) matches")
        }
    }

    private func select(_ range: NSRange) {
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        textView.showFindIndicator(for: range)
        updateFindStatus()
    }

    // MARK: FindBarDelegate

    func findBarChanged() {
        findMessage = nil
        writeFindPasteboard()
        refreshMatches()
    }

    func findBarScopeChanged() {
        if findBar.scope == .selection {
            // Each time Selection is chosen it means the text selected now.
            let selection = textView.selectedRange()
            if selection.length > 0 {
                selectionScope = selection
            } else if selectionScope == nil {
                findBar.scope = .document
                NSSound.beep()
            }
        }
        findBarChanged()
    }

    func findBarNext(backwards: Bool) {
        findMessage = nil
        guard ensureMatches() else { return NSSound.beep() }
        findBar.remember()
        let selection = textView.selectedRange()
        var target: NSRange?
        if backwards {
            // The last match that ends at or before the caret.
            var index = Self.firstIndex(in: matches, endingAfter: selection.location) { $0 } - 1
            if index >= 0, matches[index] == selection { index -= 1 }
            target = index >= 0 ? matches[index] : nil
        } else {
            let index = Self.firstIndex(in: matches, endingAfter: NSMaxRange(selection) - 1) { $0 }
            target = matches[index...].first { $0.location >= NSMaxRange(selection) && $0 != selection }
        }
        if target == nil, findBar.scope == .allDocuments {
            // Past the last match here: carry on in the next document that has one.
            let others = backwards ? otherEditors.reversed() : otherEditors
            for other in others where other.adoptFind(from: self) {
                other.window?.makeKeyAndOrderFront(nil)
                return other.select(backwards ? other.matches.last! : other.matches[0])
            }
        }
        guard let range = target ?? (backwards ? matches.last : matches.first) else {
            updateFindStatus()
            return NSSound.beep()
        }
        select(range)
    }

    /// Takes over another window's search. Returns whether this document has a match.
    private func adoptFind(from other: EditorWindowController) -> Bool {
        findBar.syncOptions()
        findBar.pattern = other.findBar.pattern
        findBar.replacement = other.findBar.replacement
        findBar.scope = .allDocuments
        matchesAreCurrent = false
        guard ensureMatches(), !matches.isEmpty else { return false }
        findBar.isHidden = false
        decorateVisible(force: true)
        return true
    }

    func findBarReplace() {
        guard let query else { return NSSound.beep() }
        findBar.remember()
        let selection = textView.selectedRange()
        if let match = query.match(at: selection, in: text) {
            let replaced = replacement.expand(match, in: text)
            textView.replace(selection, with: replaced)
            textView.setSelectedRange(NSRange(location: selection.location + (replaced as NSString).length, length: 0))
        }
        findBarNext(backwards: false)
    }

    func findBarReplaceAll() {
        guard let query else { return NSSound.beep() }
        findBar.remember()
        let replacement = self.replacement
        var editors = [self]
        if findBar.scope == .allDocuments {
            editors += otherEditors
            let counts = editors.map { query.ranges(in: $0.text).count }
            let documents = counts.filter { $0 > 0 }.count
            if documents > 1 {
                let alert = NSAlert()
                alert.messageText = "Replace \(counts.reduce(0, +)) matches in \(documents) documents?"
                alert.informativeText = "Each document can undo its own replacements."
                alert.addButton(withTitle: "Replace All")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
        }
        var total = 0
        var documents = 0
        for editor in editors {
            let range = editor === self ? searchRange : NSRange(location: 0, length: editor.text.length)
            guard let result = query.replaceAll(in: editor.text, range: range, with: replacement) else { continue }
            editor.textView.replace(result.range, with: result.text)
            total += result.count
            documents += 1
        }
        if total == 0 {
            NSSound.beep()
            findMessage = "No matches"
        } else {
            findMessage = "Replaced \(total)" + (documents > 1 ? " in \(documents) documents" : "")
        }
        updateFindStatus()
    }

    func findBarFindAll() {
        guard let query else { return NSSound.beep() }
        findBar.remember()
        var results: [FindResult] = []
        var matched: [String] = []
        var total = 0
        var documents = 0
        let editors = findBar.scope == .allDocuments ? [self] + otherEditors : [self]
        for editor in editors {
            guard let document = editor.doc else { continue }
            let text = editor.text
            let range = editor === self ? searchRange : NSRange(location: 0, length: text.length)
            let found = query.ranges(in: text, range: range)
            guard !found.isEmpty else { continue }
            total += found.count
            documents += 1
            for range in found {
                matched.append(text.substring(with: range))
                guard results.count < Self.resultLimit else { continue }
                let line = document.lineIndex.line(at: range.location)
                results.append(FindResult(
                    document: document, range: range, location: "\(document.displayName ?? ""):\(line + 1)",
                    snippet: Self.snippet(for: range, in: text)))
            }
        }
        var title = total == 1 ? "1 match" : "\(total) matches"
        if documents > 1 { title += " in \(documents) documents" }
        if total > results.count { title += ", showing the first \(results.count)" }
        resultsView.show(results, matched: matched, title: title)
        resultsView.isHidden = false
    }

    func findBarClose() {
        findBar.isHidden = true
        resultsView.isHidden = true
        selectionScope = nil
        refreshMatches()
        window?.makeFirstResponder(textView)
    }

    // MARK: Results list

    /// The matching line, trimmed around the match, with the match marked.
    private static func snippet(for match: NSRange, in text: NSString) -> NSAttributedString {
        let line = text.lineRange(for: NSRange(location: match.location, length: 0))
        var start = line.location
        var end = NSMaxRange(line)
        while start < match.location, [0x20, 0x09].contains(text.character(at: start)) { start += 1 }
        start = max(start, match.location - 60)
        end = min(end, start + 240)
        while end > start, text.character(at: end - 1) == 0x0A { end -= 1 }
        // Don't cut a surrogate pair or a combined character in half.
        let window = text.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
        let snippet = NSMutableAttributedString(
            string: text.substring(with: window),
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)])
        let marked = NSIntersectionRange(match, window)
        if marked.length > 0 {
            snippet.addAttribute(
                .backgroundColor, value: Theme.findMatch,
                range: NSRange(location: marked.location - window.location, length: marked.length))
        }
        return snippet
    }

    func reveal(_ result: FindResult) {
        guard let editor = result.document?.editor else { return }
        editor.window?.makeKeyAndOrderFront(nil)
        let length = editor.text.length
        let range = NSRange(location: min(result.range.location, length), length: 0)
        let full = NSMaxRange(result.range) <= length ? result.range : range
        editor.textView.setSelectedRange(full)
        editor.textView.scrollRangeToVisible(full)
        editor.textView.showFindIndicator(for: full)
        editor.window?.makeFirstResponder(editor.textView)
    }
}
