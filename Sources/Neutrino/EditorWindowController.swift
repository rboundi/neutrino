import AppKit
import NeutrinoCore

/// A counter that background work checks to see whether it has been superseded.
final class Generation {
    private var value = 0
    private let lock = NSLock()

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    func isCurrent(_ candidate: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value == candidate
    }
}

/// Carries a value that is safe to hand to another thread, such as an immutable copy of the text.
struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
}

/// One document's window (or tab): the text, line numbers, find bar and status bar.
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate, NSMenuItemValidation {
    /// Above this many UTF-16 units a file is shown without colours.
    static let highlightLimit = 4_000_000
    /// A scan that takes longer than this many seconds is abandoned and colours are turned off.
    static let highlightTimeout = 5.0
    /// Seconds without typing before the whole text is scanned again.
    static let fullScanDelay = 1.0
    /// Above this, background work waits for a pause in typing.
    static let debounceLimit = 400_000

    /// The views of the text: one, or two while the window is split.
    private(set) var panes: [EditorPane]
    private var activeView: EditorTextView
    private let split = NSSplitView()
    let findBar = FindBar()
    let resultsView = FindResultsView()
    let statusBar = StatusBar()
    private var style = EditorStyle.current

    /// The text view that has, or last had, the keyboard.
    var textView: EditorTextView {
        if let focused = window?.firstResponder as? EditorTextView, focused !== activeView,
            panes.contains(where: { $0.textView === focused }) {
            activeView = focused
        }
        return activeView
    }

    private(set) var tokens: [Token] = []
    /// False until the first full scan with the current syntax has finished.
    private var tokensAreValid = false
    /// The part of the text edited since the last finished scan: where it starts, and how far
    /// its end is from the end of the text, which stays true while more edits arrive.
    private var editedStart: Int?
    private var editedTail = 0
    private let tokenGeneration = Generation()
    private var editPending = false
    /// Set when the syntax proved too slow for this text; cleared when the syntax changes.
    private var highlightTimedOut = false
    /// The selected word, while its other occurrences are marked.
    private var occurrence: String?
    /// Set once something has put the caret where it should be, such as `neutrino file:42`.
    private var positionWasSet = false

    // Find state; the logic is in EditorFind.swift.
    var matches: [NSRange] = []
    var matchesAreCurrent = false
    var selectionScope: NSRange?
    var findMessage: String?
    let findGeneration = Generation()
    /// The search as last compiled, so moving the caret doesn't compile it again.
    var compiledQuery: (pattern: String, options: SearchOptions, query: SearchQuery?)?

    private static let workQueue = DispatchQueue(label: "neutrino.scan", qos: .userInitiated, attributes: .concurrent)
    var workQueue: DispatchQueue { Self.workQueue }

    var doc: Document? { document as? Document }

    /// The document is attached after `init`, so anything that reads it is refreshed here.
    override var document: AnyObject? {
        didSet {
            statusBar.update()
            updatePosition()
            updateGutterWidth()
        }
    }

    /// The text without the copy that `NSTextView.string` makes.
    var text: NSMutableString { activeView.textStorage!.mutableString }

    init(document: Document) {
        let pane = EditorPane(storage: document.textStorage)
        panes = [pane]
        activeView = pane.textView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "NeutrinoEditor"
        window.minSize = NSSize(width: 420, height: 260)
        window.center()
        super.init(window: window)
        window.delegate = self
        windowFrameAutosaveName = "Editor"

        buildLayout(in: window)
        statusBar.editor = self
        findBar.delegate = self
        resultsView.onSelect = { [weak self] in self?.reveal($0) }
        resultsView.onClose = { [weak self] in self?.resultsView.isHidden = true }

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(syntaxChanged), name: Document.syntaxDidChange, object: document)
        center.addObserver(self, selector: #selector(formatChanged), name: Document.formatDidChange, object: document)
        center.addObserver(self, selector: #selector(formatChanged), name: SyntaxStore.didChange, object: nil)
        center.addObserver(
            self, selector: #selector(defaultsChanged), name: UserDefaults.didChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(themeChanged), name: ThemeStore.didChange, object: nil)

        style = document.style
        adopt(pane, document: document)
        adoptSyntax(of: document)
        statusBar.update()
        updatePosition()
        window.makeFirstResponder(pane.textView)
        // After the first layout, which leaves the view scrolled past the space above the first line.
        DispatchQueue.main.async { [weak self] in self?.restorePosition() }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Setup

    private func buildLayout(in window: NSWindow) {
        split.isVertical = false
        split.dividerStyle = .thin
        split.addArrangedSubview(panes[0].view)

        // A plain view around the split view takes whatever height the bars leave.
        let editorArea = NSView()
        split.translatesAutoresizingMaskIntoConstraints = false
        editorArea.addSubview(split)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: editorArea.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: editorArea.trailingAnchor),
            split.topAnchor.constraint(equalTo: editorArea.topAnchor),
            split.bottomAnchor.constraint(equalTo: editorArea.bottomAnchor),
        ])

        findBar.isHidden = true
        resultsView.isHidden = true
        let stack = NSStackView(views: [findBar, editorArea, resultsView, statusBar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        // The bars keep their heights and the editor takes the rest.
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        editorArea.setContentHuggingPriority(.init(1), for: .vertical)
        editorArea.setContentCompressionResistancePriority(.init(1), for: .vertical)

        let content = NSView()
        content.addSubview(stack)
        var constraints = [
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ]
        for view in stack.arrangedSubviews {
            constraints.append(view.widthAnchor.constraint(equalTo: stack.widthAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        window.contentView = content
    }

    /// Connects a new pane to this window and gives it the current settings and syntax.
    private func adopt(_ pane: EditorPane, document: Document) {
        pane.textView.delegate = self
        pane.textView.isCode = { [weak self] index in self?.isCode(at: index) ?? true }
        pane.gutter.lineIndex = { [weak document] in document?.lineIndex ?? LineIndex() }
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(viewportChanged(_:)), name: NSView.boundsDidChangeNotification,
            object: pane.scrollView.contentView)
        center.addObserver(
            self, selector: #selector(viewportChanged(_:)), name: NSView.frameDidChangeNotification,
            object: pane.textView)
        configure(pane, from: nil)
        applySyntaxSettings(to: pane, of: document)
    }

    /// Where the caret was when the file was last closed, unless something has already moved it.
    private func restorePosition() {
        guard !positionWasSet, activeView.selectedRange().location == 0 else { return }
        if let url = doc?.fileURL, let location = Prefs.position(for: url), location <= text.length {
            let caret = NSRange(location: location, length: 0)
            activeView.setSelectedRange(caret)
            activeView.scrollRangeToVisible(caret)
        } else {
            activeView.scroll(NSPoint(x: 0, y: 0))
        }
    }

    /// Remembers the caret position for the next time this file is opened.
    func savePosition() {
        guard let url = doc?.fileURL else { return }
        Prefs.setPosition(activeView.selectedRange().location, for: url)
    }

    // MARK: Settings

    @objc private func defaultsChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let new = self.doc?.style ?? EditorStyle.current
            if new != self.style { self.apply(new) }
        }
    }

    private func apply(_ new: EditorStyle) {
        let old = style
        style = new
        if old.fontName != new.fontName || old.fontSize != new.fontSize || old.tabWidth != new.tabWidth,
            let storage = activeView.textStorage {
            storage.setAttributes(new.textAttributes, range: NSRange(location: 0, length: storage.length))
        }
        if old.theme != new.theme { recolourText() }
        for pane in panes { configure(pane, from: old) }
        statusBar.update()
    }

    /// Applies the settings to one pane. `old` is what it had before; nil for a new pane.
    private func configure(_ pane: EditorPane, from old: EditorStyle?) {
        let new = style
        pane.textView.style = new
        if old == nil || old?.fontName != new.fontName || old?.fontSize != new.fontSize || old?.tabWidth != new.tabWidth {
            pane.textView.typingAttributes = new.textAttributes
            pane.layoutManager.invisiblesFont = new.font
            pane.gutter.font = .monospacedDigitSystemFont(ofSize: max(9, CGFloat(new.fontSize) - 2), weight: .regular)
        }
        if old == nil || old?.wrapLines != new.wrapLines { pane.applyWrap(new.wrapLines) }
        if let old, old.theme != new.theme { pane.applyTheme() }
        // Only when the setting itself changes, so a choice made in the text's own menu stays.
        if old?.checkSpelling != new.checkSpelling {
            pane.textView.isContinuousSpellCheckingEnabled = new.checkSpelling
        }
        pane.setLineNumbers(shown: new.lineNumbers, lineCount: doc?.lineIndex.count ?? 1)
        pane.layoutManager.showsInvisibles = new.showInvisibles
        pane.decorated.length = 0
        pane.textView.needsDisplay = true
        pane.gutter.needsDisplay = true
        decorate(pane)
    }

    @objc private func themeChanged() {
        recolourText()
        for pane in panes {
            pane.applyTheme()
            pane.decorated.length = 0
            decorate(pane)
        }
    }

    /// Gives all the text the theme's text colour. Syntax colours are looked up again when the
    /// visible text is next decorated.
    private func recolourText() {
        guard let storage = activeView.textStorage else { return }
        storage.addAttribute(.foregroundColor, value: Theme.text, range: NSRange(location: 0, length: storage.length))
        for pane in panes { pane.textView.typingAttributes = style.textAttributes }
    }

    private func updateGutterWidth() {
        for pane in panes {
            pane.setLineNumbers(shown: style.lineNumbers, lineCount: doc?.lineIndex.count ?? 1)
        }
    }

    // MARK: Split

    /// Shows the document in two halves that scroll separately, or goes back to one.
    @objc func toggleSplit(_ sender: Any?) {
        guard let doc else { return }
        if panes.count > 1 {
            let closing = panes.removeLast()
            let center = NotificationCenter.default
            center.removeObserver(self, name: NSView.boundsDidChangeNotification, object: closing.scrollView.contentView)
            center.removeObserver(self, name: NSView.frameDidChangeNotification, object: closing.textView)
            closing.textView.delegate = nil
            closing.view.removeFromSuperview()
            doc.textStorage.removeLayoutManager(closing.layoutManager)
            activeView = panes[0].textView
            window?.makeFirstResponder(activeView)
            return
        }
        let first = panes[0]
        let pane = EditorPane(storage: doc.textStorage)
        panes.append(pane)
        split.addArrangedSubview(pane.view)
        split.layoutSubtreeIfNeeded()
        split.setPosition(split.bounds.height / 2, ofDividerAt: 0)
        adopt(pane, document: doc)
        // The new half starts where the first one is.
        let caret = NSRange(location: first.textView.selectedRange().location, length: 0)
        pane.textView.setSelectedRange(caret)
        pane.textView.scrollRangeToVisible(caret)
        window?.makeFirstResponder(pane.textView)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleSplit(_:)) {
            menuItem.state = panes.count > 1 ? .on : .off
        }
        return true
    }

    /// Stops or allows typing in every pane.
    func setEditable(_ editable: Bool) {
        for pane in panes { pane.textView.isEditable = editable }
    }

    // MARK: Syntax colours

    @objc private func syntaxChanged() {
        guard let doc else { return }
        adoptSyntax(of: doc)
        statusBar.update()
    }

    private func applySyntaxSettings(to pane: EditorPane, of document: Document) {
        let definition = document.syntax?.definition
        pane.textView.lineComment = definition?.lineComment
        pane.textView.blockComment = definition?.blockComment
        pane.textView.indentWithTabs = definition?.indentWithTabs == true
        pane.textView.indentAfterColon = definition?.indentAfterColon == true
    }

    private func adoptSyntax(of document: Document) {
        tokens = []
        tokensAreValid = false
        editedStart = nil
        highlightTimedOut = false
        let whole = NSRange(location: 0, length: document.textStorage.length)
        for pane in panes {
            applySyntaxSettings(to: pane, of: document)
            pane.layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: whole)
            pane.decorated.length = 0
        }
        scheduleHighlight(of: document)
    }

    private func scheduleHighlight(of document: Document) {
        let generation = tokenGeneration.next()
        let length = document.textStorage.length
        guard let syntax = document.syntax, !highlightTimedOut, length > 0, length <= Self.highlightLimit else {
            tokensAreValid = false
            if !tokens.isEmpty {
                tokens = []
                decorateVisible(force: true)
            }
            return
        }
        let delay = length > Self.debounceLimit ? 0.2 : 0
        after(delay) { [weak self, weak document] in
            guard let self, let document, self.tokenGeneration.isCurrent(generation) else { return }
            let snapshot = Unchecked(value: document.snapshotText())
            // After the first scan, only the edited part is scanned again.
            let previous = self.tokensAreValid ? self.tokens : nil
            let length = snapshot.value.length
            let start = min(self.editedStart ?? 0, length)
            let edited = NSRange(location: start, length: max(length - self.editedTail - start, 0))
            self.workQueue.async {
                let deadline = Date().addingTimeInterval(Self.highlightTimeout)
                var timedOut = false
                let cancelled = {
                    timedOut = Date() > deadline
                    return timedOut || !self.tokenGeneration.isCurrent(generation)
                }
                var tokens: [Token]
                if let previous {
                    tokens = syntax.retokenize(snapshot.value, previous: previous, edited: edited, isCancelled: cancelled)
                } else {
                    tokens = syntax.tokenize(snapshot.value, isCancelled: cancelled)
                }
                if timedOut { tokens = [] }
                let gaveUp = timedOut
                DispatchQueue.main.async {
                    guard self.tokenGeneration.isCurrent(generation) else { return }
                    self.highlightTimedOut = gaveUp
                    self.tokens = tokens
                    self.tokensAreValid = !gaveUp
                    self.editedStart = nil
                    self.decorateVisible(force: true)
                    if previous != nil { self.scheduleFullScan() }
                }
            }
        }
    }

    /// Scans the whole text again once typing has paused. The quick rescan after each edit
    /// starts just before the edit, so it can miss a token further back that the edit completed.
    private func scheduleFullScan() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(fullScan), object: nil)
        // Scanning a large file takes a while, so wait for a longer pause there.
        let large = (doc?.textStorage.length ?? 0) > Self.debounceLimit
        perform(#selector(fullScan), with: nil, afterDelay: large ? Self.fullScanDelay * 3 : Self.fullScanDelay)
    }

    @objc private func fullScan() {
        guard let doc, tokensAreValid, editedStart == nil else { return }
        tokensAreValid = false
        scheduleHighlight(of: doc)
    }

    /// Whether the character is code, as opposed to part of a string or a comment.
    private func isCode(at index: Int) -> Bool {
        let found = Self.firstIndex(in: tokens, endingAfter: index) { $0.range }
        guard found < tokens.count, tokens[found].range.location <= index else { return true }
        return tokens[found].scope != .comment && tokens[found].scope != .string
    }

    func after(_ delay: Double, _ work: @escaping () -> Void) {
        if delay == 0 { work() } else { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) }
    }

    /// Index of the first range that ends after `location`. `ranges` must be sorted.
    static func firstIndex<T>(in items: [T], endingAfter location: Int, range: (T) -> NSRange) -> Int {
        var low = 0
        var high = items.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(range(items[mid])) > location { high = mid } else { low = mid + 1 }
        }
        return low
    }

    /// Colours the text on screen in every pane.
    func decorateVisible(force: Bool = false) {
        for pane in panes { decorate(pane, force: force) }
    }

    /// Colours the text on screen, plus a margin so short scrolls need no work.
    /// Only that part gets attributes, which keeps large files cheap.
    private func decorate(_ pane: EditorPane, force: Bool = false) {
        let onScreen = pane.visibleCharacters(padded: false)
        if !force, pane.decorated.length > 0, onScreen.location >= pane.decorated.location,
            NSMaxRange(onScreen) <= NSMaxRange(pane.decorated) {
            return
        }
        let range = pane.visibleCharacters(padded: true)
        pane.decorated = range
        let layoutManager = pane.layoutManager

        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
        let end = NSMaxRange(range)
        var index = Self.firstIndex(in: tokens, endingAfter: range.location) { $0.range }
        while index < tokens.count, tokens[index].range.location < end {
            let part = NSIntersectionRange(tokens[index].range, range)
            if part.length > 0 {
                layoutManager.addTemporaryAttribute(
                    .foregroundColor, value: Theme.color(for: tokens[index].scope), forCharacterRange: part)
            }
            index += 1
        }
        if let occurrence {
            let selected = pane.textView.selectedRange()
            var search = range
            while search.length > 0 {
                let found = text.range(of: occurrence, options: .literal, range: search)
                guard found.location != NSNotFound else { break }
                if found != selected, isWholeWord(found) {
                    layoutManager.addTemporaryAttribute(.backgroundColor, value: Theme.occurrence, forCharacterRange: found)
                }
                search = NSRange(location: NSMaxRange(found), length: end - NSMaxRange(found))
            }
        }
        guard !findBar.isHidden else { return }
        index = Self.firstIndex(in: matches, endingAfter: range.location) { $0 }
        while index < matches.count, matches[index].location < end {
            let part = NSIntersectionRange(matches[index], range)
            if part.length > 0 {
                layoutManager.addTemporaryAttribute(.backgroundColor, value: Theme.findMatch, forCharacterRange: part)
            }
            index += 1
        }
    }

    private func invalidateDecoration() {
        for pane in panes { pane.decorated.length = 0 }
    }

    // MARK: Occurrences of the selected word

    private static let wordCharacters: NSCharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert("_")
        return set as NSCharacterSet
    }()

    /// Whether the range has no letter, digit or underscore directly before or after it.
    private func isWholeWord(_ range: NSRange) -> Bool {
        let words = Self.wordCharacters
        if range.location > 0, words.characterIsMember(text.character(at: range.location - 1)) { return false }
        let end = NSMaxRange(range)
        return end >= text.length || !words.characterIsMember(text.character(at: end))
    }

    /// The selection, when it is exactly one word; its other occurrences get marked.
    private func selectedWord() -> String? {
        let selection = activeView.selectedRange()
        guard selection.length >= 2, selection.length <= 100, NSMaxRange(selection) <= text.length,
            isWholeWord(selection)
        else { return nil }
        for index in selection.location..<NSMaxRange(selection)
        where !Self.wordCharacters.characterIsMember(text.character(at: index)) {
            return nil
        }
        return text.substring(with: selection)
    }

    private func updateOccurrences() {
        let word = selectedWord()
        guard word != occurrence else { return }
        occurrence = word
        decorateVisible(force: true)
    }

    // MARK: Edits and scrolling

    /// Called by the document while the text storage is still processing the edit,
    /// so this only fixes up offsets; the visible work happens right after.
    func textDidEdit(newRange: NSRange, delta: Int) {
        let oldEnd = newRange.location + newRange.length - delta
        CompiledSyntax.shift(&tokens, edited: newRange, delta: delta)
        let tail = text.length - NSMaxRange(newRange)
        if let start = editedStart {
            editedStart = min(start, newRange.location)
            editedTail = min(editedTail, tail)
        } else {
            editedStart = newRange.location
            editedTail = tail
        }

        matchesAreCurrent = false
        let index = Self.firstIndex(in: matches, endingAfter: newRange.location) { $0 }
        let firstAfter = matches[index...].firstIndex { $0.location >= oldEnd } ?? matches.count
        matches.removeSubrange(index..<firstAfter)
        for i in index..<matches.count { matches[i].location += delta }
        if var scope = selectionScope {
            if newRange.location < scope.location {
                scope.location = max(newRange.location, scope.location + delta)
            } else if newRange.location <= NSMaxRange(scope) {
                scope.length = max(0, scope.length + delta)
            }
            selectionScope = scope
        }

        guard !editPending else { return }
        editPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let doc = self.doc else { return }
            self.editPending = false
            self.invalidateDecoration()
            self.updateGutterWidth()
            for pane in self.panes { pane.gutter.needsDisplay = true }
            self.scheduleHighlight(of: doc)
            self.refreshMatches()
            self.updatePosition()
        }
    }

    @objc private func viewportChanged(_ notification: Notification) {
        let source = notification.object as AnyObject?
        guard let pane = panes.first(where: { $0.textView === source || $0.scrollView.contentView === source })
        else { return }
        pane.gutter.needsDisplay = true
        decorate(pane)
    }

    @objc private func formatChanged() {
        statusBar.update()
        guard let doc else { return }
        // The document may have picked up an .editorconfig after being saved under a new name.
        let new = doc.style
        if new != style { apply(new) }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        let changed = notification.object as? EditorTextView ?? activeView
        changed.updateCurrentLine()
        changed.updateBracketMatch()
        panes.first { $0.textView === changed }?.gutter.needsDisplay = true
        guard changed === textView else { return }
        updateOccurrences()
        updatePosition()
        if !findBar.isHidden { updateFindStatus() }
    }

    private func updatePosition() {
        guard let index = doc?.lineIndex else { return }
        let view = activeView
        let selection = view.selectedRange()
        let line = index.line(at: selection.location)
        var label = "Line \(line + 1), Column \(selection.location - index.start(ofLine: line) + 1)"
        if view.cursorCount > 1 {
            label = "\(view.cursorCount) cursors"
        } else if selection.length > 0 {
            var parts: [String] = []
            // Counting words reads the selection, so not for a very large one on every change.
            if selection.length <= 1_000_000 {
                parts.append(Self.count(TextStats.words(in: text, range: selection), "word"))
            }
            parts.append(Self.count(selection.length, "character"))
            let lines = index.line(at: NSMaxRange(selection)) - line + 1
            if lines > 1 { parts.append(Self.count(lines, "line")) }
            label += "  (\(parts.joined(separator: ", ")) selected)"
        }
        statusBar.setPosition(label)
    }

    private static func count(_ number: Int, _ noun: String) -> String {
        "\(number.formatted()) \(noun)\(number == 1 ? "" : "s")"
    }

    /// Shows the size of the whole document in the status bar until the caret next moves.
    func showDocumentCounts() {
        guard let index = doc?.lineIndex else { return }
        let whole = NSRange(location: 0, length: text.length)
        statusBar.setPosition([
            Self.count(index.count, "line"), Self.count(TextStats.words(in: text, range: whole), "word"),
            Self.count(whole.length, "character"),
        ].joined(separator: ", "))
    }

    // MARK: Window

    func windowDidBecomeKey(_ notification: Notification) {
        syncFindPasteboard()
    }

    func windowDidResignKey(_ notification: Notification) {
        doc?.autosaveNow()
    }

    override func newWindowForTab(_ sender: Any?) {
        NSDocumentController.shared.newDocument(sender)
    }

    // MARK: Saving

    /// Applies "trim trailing whitespace" and "end with a newline" as ordinary undoable edits.
    func tidyBeforeSaving() {
        let defaults = UserDefaults.standard
        let config = doc?.editorConfig ?? EditorConfig()
        if config.trimTrailingWhitespace ?? defaults.bool(forKey: Prefs.trimTrailingWhitespace),
            let query = try? SearchQuery(pattern: "[ \\t]+$", options: SearchOptions(regex: true)),
            let result = query.replaceAll(in: text, with: Replacement(template: "", isRegex: false)) {
            let caret = textView.selectedRange().location
            textView.replace(result.range, with: result.text)
            textView.setSelectedRange(NSRange(location: min(caret, text.length), length: 0))
        }
        if config.insertFinalNewline ?? defaults.bool(forKey: Prefs.ensureFinalNewline), text.length > 0,
            text.character(at: text.length - 1) != 0x0A {
            let selection = textView.selectedRange()
            textView.replace(NSRange(location: text.length, length: 0), with: "\n")
            textView.setSelectedRange(selection)
        }
    }

    // MARK: Go to line

    @objc func goToLine(_ sender: Any?) {
        guard let index = doc?.lineIndex, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Go to Line"
        alert.informativeText = "A line number, or line:column. This file has \(index.count) lines."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 22))
        field.placeholderString = "120 or 120:8"
        alert.accessoryView = field
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let parts = field.stringValue.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            guard let line = parts.first else { return }
            self.go(toLine: line, column: parts.count > 1 ? parts[1] : 1)
        }
    }

    /// Puts the caret at a line and column, both counted from 1.
    func go(toLine line: Int, column: Int = 1) {
        guard let index = doc?.lineIndex, line >= 1 else { return }
        let target = min(line, index.count) - 1
        let start = index.start(ofLine: target)
        let lineEnd = target + 1 < index.count ? index.start(ofLine: target + 1) - 1 : text.length
        let range = NSRange(location: min(start + max(column, 1) - 1, lineEnd), length: 0)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        window?.makeFirstResponder(textView)
        positionWasSet = true
    }
}
