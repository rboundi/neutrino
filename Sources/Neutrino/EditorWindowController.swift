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

/// The line between the two halves of a split window. It is taller than the line it draws, so it
/// is easy to catch; dragging it resizes the halves and a double click makes them equal again.
final class SplitDivider: NSView {
    /// Called with the pointer's position in the window while the divider is dragged.
    var onDrag: (NSPoint) -> Void = { _ in }
    var onReset: () -> Void = {}

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 8) }

    override func draw(_ dirtyRect: NSRect) {
        Theme.background.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: (bounds.midY - 1).rounded(.down), width: bounds.width, height: 2).fill()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onReset() }
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag(event.locationInWindow)
    }
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
    /// Holds the panes: one filling it, or two with a line between them that can be dragged.
    private let editorArea = NSView()
    private let divider = SplitDivider()
    private var paneConstraints: [NSLayoutConstraint] = []
    /// The share of the editor area the upper pane takes while the window is split.
    private var splitRatio: CGFloat = 0.5
    private var splitHeight: NSLayoutConstraint?
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
    /// Whether the document is read-only for now, by the lock in the status bar.
    private(set) var isLocked = false
    /// True while a shell command runs on the text.
    private var isBusy = false
    /// Where the text was edited lately, most recent last, for Go to Last Edit.
    private var editPlaces: [Int] = []
    private var editPlaceIndex: Int?
    /// The folded parts of the text; see `EditorLayoutManager.folds`.
    private var folds: [NSRange] = []
    /// Folds an edit ran into, to be laid out again once the edit is done.
    private var brokenFolds: [NSRange] = []
    /// The table shown in place of the text, for a CSV file.
    private var tableView: DelimitedTableView?
    /// The bytes shown in place of the text, for a file that isn't text.
    private var hexView: HexView?
    /// Which reading of the file the bytes shown are from; see `Document.readCount`.
    private var shownRead = 0
    /// The lines changed since the file was opened or saved, for the marks beside them.
    private var changes = ChangedLines()
    private let changeGeneration = Generation()
    /// Bookmarked lines, each kept as a place in the text so it moves with edits.
    private var bookmarks: [Int] = []
    private var caretLine = 0
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
            // A file that can't be written starts locked, so typing doesn't lead to a failed save.
            if let path = doc?.fileURL?.path, FileManager.default.fileExists(atPath: path),
                !FileManager.default.isWritableFile(atPath: path) {
                isLocked = true
                updateEditable()
            }
            statusBar.update()
            updatePosition()
            updateGutterWidth()
            updateTitleButton()
            updateHexView()
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
        DispatchQueue.main.async { [weak self] in
            self?.restoreFolds()
            self?.restorePosition()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Setup

    private func buildLayout(in window: NSWindow) {
        divider.onDrag = { [weak self] y in self?.moveDivider(to: y) }
        divider.onReset = { [weak self] in self?.setSplitRatio(0.5) }
        layoutPanes()

        findBar.isHidden = true
        resultsView.isHidden = true
        let stack = NSStackView(views: [findBar, editorArea, resultsView, statusBar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        editorArea.setContentHuggingPriority(.defaultLow, for: .vertical)

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

    /// Puts the panes in the editor area. A split view would do this too, but it sizes its
    /// parts by their own preferences and collapsed the text when the find bar opened.
    private func layoutPanes() {
        NSLayoutConstraint.deactivate(paneConstraints)
        editorArea.subviews.forEach { $0.removeFromSuperview() }
        let views = panes.map(\.view)
        var constraints = [
            views[0].topAnchor.constraint(equalTo: editorArea.topAnchor),
            views[views.count - 1].bottomAnchor.constraint(equalTo: editorArea.bottomAnchor),
        ]
        for view in views + (views.count > 1 ? [divider] : []) {
            view.translatesAutoresizingMaskIntoConstraints = false
            editorArea.addSubview(view)
            constraints += [
                view.leadingAnchor.constraint(equalTo: editorArea.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: editorArea.trailingAnchor),
            ]
        }
        if views.count > 1 {
            constraints += [
                divider.topAnchor.constraint(equalTo: views[0].bottomAnchor),
                views[1].topAnchor.constraint(equalTo: divider.bottomAnchor),
                // Neither half can be dragged down to nothing.
                views[0].heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumPaneHeight),
                views[1].heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumPaneHeight),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        paneConstraints = constraints
        splitHeight = nil
        if views.count > 1 { setSplitRatio(splitRatio) }
    }

    private static let minimumPaneHeight: CGFloat = 60

    /// Gives the upper pane this share of the height. A share rather than a fixed height, so
    /// both halves grow and shrink with the window.
    private func setSplitRatio(_ ratio: CGFloat) {
        guard panes.count > 1 else { return }
        splitRatio = min(max(ratio, 0.05), 0.95)
        splitHeight?.isActive = false
        let height = panes[0].view.heightAnchor.constraint(equalTo: editorArea.heightAnchor, multiplier: splitRatio)
        // Weak enough that the minimum heights win in a short window, and that it can never
        // make the window itself taller.
        height.priority = .dragThatCannotResizeWindow
        height.isActive = true
        splitHeight = height
    }

    /// Called while the divider is dragged, with the pointer's position in the window.
    private func moveDivider(to point: NSPoint) {
        let height = editorArea.bounds.height
        guard height > 0 else { return }
        let y = editorArea.convert(point, from: nil).y
        // The editor area isn't flipped: y counts up from the bottom.
        let top = editorArea.isFlipped ? y : height - y
        let least = Self.minimumPaneHeight
        guard height > 2 * least else { return }
        setSplitRatio(min(max(top, least), height - least) / height)
    }

    /// Connects a new pane to this window and gives it the current settings and syntax.
    private func adopt(_ pane: EditorPane, document: Document) {
        pane.textView.delegate = self
        pane.textView.isCode = { [weak self] index in self?.isCode(at: index) ?? true }
        pane.gutter.lineIndex = { [weak document] in document?.lineIndex ?? LineIndex() }
        pane.gutter.bookmarks = { [weak self] in self?.bookmarkedLines() ?? [] }
        pane.gutter.foldMark = { [weak self] in self?.foldMark(forLineAt: $0) ?? 0 }
        pane.gutter.onFoldClick = { [weak self] in self?.toggleFold(atLine: $0) }
        pane.gutter.changes = { [weak self] in self?.changes ?? ChangedLines() }
        pane.layoutManager.folds = folds
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(viewportChanged(_:)), name: NSView.boundsDidChangeNotification,
            object: pane.scrollView.contentView)
        center.addObserver(
            self, selector: #selector(viewportChanged(_:)), name: NSView.frameDidChangeNotification,
            object: pane.textView)
        configure(pane, from: nil)
        applySyntaxSettings(to: pane, of: document)
        pane.textView.isEditable = !isLocked && !isBusy && hexView == nil
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

    /// Remembers the caret position and the folded blocks for the next time this file is opened.
    func savePosition() {
        guard let url = doc?.fileURL, hexView == nil else { return }
        Prefs.setPosition(activeView.selectedRange().location, for: url)
        Prefs.setFolds(folds, for: url, textLength: text.length)
    }

    /// Folds what was folded when the file was last closed.
    private func restoreFolds() {
        guard folds.isEmpty, let url = doc?.fileURL else { return }
        let saved = Prefs.folds(for: url, textLength: text.length).sorted { $0.location < $1.location }
        if !saved.isEmpty { setFolds(saved, changed: saved) }
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
        hexView?.setFontSize(new.fontSize)
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
        if let old, old.changeMarks != new.changeMarks { scheduleChangeMarks() }
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
        hexView?.applyTheme()
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
            doc.textStorage.removeLayoutManager(closing.layoutManager)
            layoutPanes()
            activeView = panes[0].textView
            window?.makeFirstResponder(activeView)
            return
        }
        let first = panes[0]
        let pane = EditorPane(storage: doc.textStorage)
        panes.append(pane)
        layoutPanes()
        editorArea.layoutSubtreeIfNeeded()
        adopt(pane, document: doc)
        // The new half starts where the first one is.
        let caret = NSRange(location: first.textView.selectedRange().location, length: 0)
        pane.textView.setSelectedRange(caret)
        pane.textView.scrollRangeToVisible(caret)
        window?.makeFirstResponder(pane.textView)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleSplit(_:)):
            menuItem.state = panes.count > 1 ? .on : .off
            return tableView == nil && hexView == nil
        case #selector(toggleTable(_:)):
            menuItem.state = tableView != nil ? .on : .off
            return tableView != nil || isDelimitedFile
        case #selector(unfoldAll(_:)): return !folds.isEmpty
        case #selector(foldLevel(_:)): return text.length > 0 && tableView == nil
        case #selector(copyJSONPath(_:)): return isJSON
        case #selector(keepMatchingLines(_:)), #selector(deleteMatchingLines(_:)):
            return !findBar.pattern.isEmpty && !isLocked && tableView == nil
        case #selector(showFind(_:)), #selector(showFindInDocuments(_:)), #selector(goToLine(_:)):
            return hexView == nil
        case #selector(toggleLock(_:)): menuItem.state = isLocked ? .on : .off
        case #selector(goToLastEdit(_:)): return !editPlaces.isEmpty
        case #selector(nextBookmark(_:)), #selector(previousBookmark(_:)), #selector(clearBookmarks(_:)):
            return !bookmarks.isEmpty
        default: break
        }
        return true
    }

    /// Stops typing in every pane while a command works on the text, and allows it again after.
    func setEditable(_ editable: Bool) {
        isBusy = !editable
        updateEditable()
    }

    private func updateEditable() {
        for pane in panes { pane.textView.isEditable = !isLocked && !isBusy && hexView == nil }
    }

    /// Makes the document read-only, or editable again.
    @objc func toggleLock(_ sender: Any?) {
        guard hexView == nil else { return NSSound.beep() }
        isLocked.toggle()
        updateEditable()
        statusBar.update()
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
        pane.textView.isMarkdown = definition?.id == "markdown"
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
        layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: range)
        layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: range)
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
        if style.markTrailingSpaces { markTrailingSpaces(in: range, of: pane) }
        if style.showColours { underlineColours(in: range, of: pane) }
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

    /// Above this many characters on screen (a file that is one enormous line), the extra
    /// marks are skipped.
    private static let markLimit = 200_000

    /// A red background on spaces and tabs at the end of lines, except right behind the caret,
    /// where they are still being typed.
    private func markTrailingSpaces(in range: NSRange, of pane: EditorPane) {
        guard range.length <= Self.markLimit else { return }
        let caret = pane.textView.selectedRange().location
        let end = NSMaxRange(range)
        var run = range.location
        for index in range.location...end {
            let c: unichar = index < text.length ? text.character(at: index) : 0x0A
            if c == 0x20 || c == 0x09, index < end { continue }
            if c == 0x0A, index > run, index != caret {
                pane.layoutManager.addTemporaryAttribute(
                    .backgroundColor, value: Theme.trailingSpace,
                    forCharacterRange: NSRange(location: run, length: index - run))
            }
            run = index + 1
        }
    }

    private static let hexColour = try! NSRegularExpression(
        pattern: "#(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{3})(?![0-9a-zA-Z_])")

    /// A thick underline under each hex colour, in that colour.
    private func underlineColours(in range: NSRange, of pane: EditorPane) {
        guard range.length <= Self.markLimit else { return }
        let visible = text.substring(with: range) as NSString
        Self.hexColour.enumerateMatches(in: visible as String, range: NSRange(location: 0, length: visible.length)) { match, _, _ in
            guard let match else { return }
            var digits = visible.substring(with: NSRange(location: match.range.location + 1, length: match.range.length - 1))
            if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
            guard let value = UInt64(digits.prefix(6), radix: 16) else { return }
            let colour = NSColor(
                srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255,
                blue: CGFloat(value & 0xff) / 255, alpha: 1)
            pane.layoutManager.addTemporaryAttributes(
                [.underlineStyle: NSUnderlineStyle.thick.rawValue, .underlineColor: colour],
                forCharacterRange: NSRange(location: range.location + match.range.location, length: match.range.length))
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

        // Earlier places move with the text; the newest is where this edit ended.
        for i in editPlaces.indices {
            if editPlaces[i] >= oldEnd {
                editPlaces[i] += delta
            } else if editPlaces[i] > newRange.location {
                editPlaces[i] = newRange.location
            }
        }
        // A fold after the edit moves with the text; one the edit ran into is opened.
        var kept: [NSRange] = []
        for var fold in folds {
            if fold.location >= oldEnd {
                fold.location += delta
            } else if NSMaxRange(fold) > newRange.location {
                brokenFolds.append(NSRange(location: fold.location, length: max(fold.length + delta, 0) + newRange.length))
                continue
            }
            kept.append(fold)
        }
        if kept != folds || delta != 0 {
            folds = kept
            for pane in panes { pane.layoutManager.folds = kept }
        }
        for i in bookmarks.indices {
            if bookmarks[i] >= oldEnd {
                bookmarks[i] += delta
            } else if bookmarks[i] > newRange.location {
                bookmarks[i] = newRange.location
            }
        }
        let here = NSMaxRange(newRange)
        if let last = editPlaces.last, abs(last - here) < 80 {
            editPlaces[editPlaces.count - 1] = here
        } else {
            editPlaces.append(here)
            if editPlaces.count > 20 { editPlaces.removeFirst() }
        }
        editPlaceIndex = nil

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
            if !self.brokenFolds.isEmpty {
                for pane in self.panes { pane.layoutManager.refold(self.brokenFolds) }
                self.brokenFolds = []
            }
            if self.tableView != nil { self.showTable() }
            self.invalidateDecoration()
            self.updateGutterWidth()
            for pane in self.panes { pane.gutter.needsDisplay = true }
            self.scheduleHighlight(of: doc)
            self.refreshMatches()
            self.updatePosition()
            self.scheduleChangeMarks()
        }
    }

    // MARK: Changed lines

    /// Called by the document when the text it compares with is replaced: on opening, on
    /// reverting, and after a save by hand.
    func baselineChanged() {
        scheduleChangeMarks(delay: 0)
    }

    /// Works out which lines differ from the file as it was opened or saved, once typing has
    /// paused, and off the main thread.
    private func scheduleChangeMarks(delay: Double = 0.4) {
        let generation = changeGeneration.next()
        guard style.changeMarks, let doc, let baseline = doc.baseline, text.length <= Document.changeMarkLimit else {
            return setChanges(ChangedLines())
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak doc] in
            guard let self, let doc, self.changeGeneration.isCurrent(generation) else { return }
            // Nothing unsaved and nothing to undo: the text is the one that was read.
            if !doc.isDocumentEdited, doc.undoManager?.canUndo != true { return self.setChanges(ChangedLines()) }
            let snapshot = Unchecked(value: doc.snapshotText())
            self.workQueue.async {
                let found = ChangedLines.compare(old: baseline, new: LineHashes.make(snapshot.value))
                DispatchQueue.main.async {
                    if self.changeGeneration.isCurrent(generation) { self.setChanges(found) }
                }
            }
        }
    }

    private func setChanges(_ new: ChangedLines) {
        guard new != changes else { return }
        changes = new
        for pane in panes { pane.gutter.needsDisplay = true }
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
        updateHexView()
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
        // A caret that lands inside a fold, from a search or Go to Line, opens it.
        let caret = changed.selectedRange()
        let entered = folds.filter { caret.location > $0.location && caret.location < NSMaxRange($0) }
        if !entered.isEmpty { setFolds(folds.filter { !entered.contains($0) }, changed: entered) }
        guard changed === textView else { return }
        if style.markTrailingSpaces, let line = doc?.lineIndex.line(at: changed.selectedRange().location),
            line != caretLine {
            // The line the caret left may have spaces at its end that now get marked.
            caretLine = line
            decorateVisible(force: true)
        }
        updateOccurrences()
        updatePosition()
        if !findBar.isHidden { updateFindStatus() }
    }

    private func updatePosition() {
        guard let index = doc?.lineIndex else { return }
        if let data = doc?.binaryData {
            var label = Self.count(data.count, "byte")
            if data.count > HexView.limit { label += ", the first 16 MB shown" }
            return statusBar.setPosition(label)
        }
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
        } else if isJSON, let path = JSONPath.path(in: text, at: selection.location) {
            label += "  \(path)"
        }
        statusBar.setPosition(label)
    }

    private var isJSON: Bool {
        doc?.syntax?.definition.id == "json"
            || ["json", "jsonc", "geojson", "webmanifest"].contains(doc?.fileURL?.pathExtension.lowercased() ?? "")
    }

    /// Copies where the caret is in a JSON document, such as `items[3].name`.
    @objc func copyJSONPath(_ sender: Any?) {
        guard let path = JSONPath.path(in: text, at: textView.selectedRange().location) else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        statusBar.setPosition("Copied \(path)")
    }

    private static func count(_ number: Int, _ noun: String) -> String {
        "\(number.formatted()) \(noun)\(number == 1 ? "" : "s")"
    }

    private static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...4)))
    }

    /// Shows the size of the whole document in the status bar until the caret next moves, or
    /// what the numbers in the selection add up to when it has some.
    func showDocumentCounts() {
        guard let index = doc?.lineIndex, hexView == nil else { return }
        let selection = activeView.selectedRange()
        if selection.length > 0, selection.length <= 1_000_000,
            let numbers = TextStats.numbers(in: text.substring(with: selection)), numbers.count > 1 {
            return statusBar.setPosition(
                "\(Self.count(numbers.count, "number")): sum \(Self.number(numbers.sum)), "
                    + "average \(Self.number(numbers.sum / Double(numbers.count))), "
                    + "least \(Self.number(numbers.min)), most \(Self.number(numbers.max))")
        }
        let whole = NSRange(location: 0, length: text.length)
        var parts = [
            Self.count(index.count, "line"), Self.count(TextStats.words(in: text, range: whole), "word"),
            Self.count(whole.length, "character"),
        ]
        // The character after the caret, by its Unicode number and name.
        let caret = activeView.selectedRange().location
        if caret < text.length,
            let scalar = text.substring(with: text.rangeOfComposedCharacterSequence(at: caret)).unicodeScalars.first {
            let code = String(scalar.value, radix: 16, uppercase: true)
            let padded = String(repeating: "0", count: max(4 - code.count, 0)) + code
            parts.append("at caret: U+\(padded) \(scalar.properties.name ?? "")")
        }
        statusBar.setPosition(parts.joined(separator: ", "))
    }

    // MARK: Places

    /// Goes to where the text was last edited; used again, to the edit before that.
    @objc func goToLastEdit(_ sender: Any?) {
        guard !editPlaces.isEmpty else { return NSSound.beep() }
        var index = (editPlaceIndex ?? editPlaces.count) - 1
        if index < 0 { index = editPlaces.count - 1 }
        editPlaceIndex = index
        let caret = NSRange(location: min(editPlaces[index], text.length), length: 0)
        textView.setSelectedRange(caret)
        textView.scrollRangeToVisible(caret)
        window?.makeFirstResponder(textView)
    }

    // MARK: Folding

    private func setFolds(_ new: [NSRange], changed: [NSRange]) {
        folds = new
        for pane in panes {
            pane.layoutManager.folds = new
            pane.layoutManager.refold(changed)
            pane.decorated.length = 0
            pane.gutter.needsDisplay = true
            pane.textView.needsDisplay = true
        }
        decorateVisible()
    }

    /// The fold that starts on the line beginning at `start`, if there is one.
    private func fold(onLineAt start: Int) -> NSRange? {
        guard !folds.isEmpty else { return nil }
        let line = text.lineRange(for: NSRange(location: min(start, text.length), length: 0))
        // The folds are sorted by where they start.
        var low = 0
        var high = folds.count
        while low < high {
            let mid = (low + high) / 2
            if folds[mid].location > line.location { high = mid } else { low = mid + 1 }
        }
        return low < folds.count && folds[low].location <= NSMaxRange(line) ? folds[low] : nil
    }

    private func foldMark(forLineAt start: Int) -> Int {
        if fold(onLineAt: start) != nil { return 2 }
        return Folding.isFoldable(in: text, lineStart: start, tabWidth: style.tabWidth) ? 1 : 0
    }

    /// Folds the block that starts on this line, or opens it if it is folded.
    private func toggleFold(atLine start: Int) {
        if let existing = fold(onLineAt: start) {
            return setFolds(folds.filter { $0 != existing }, changed: [existing])
        }
        guard let range = Folding.range(
            in: text, lineStart: start, tabWidth: style.tabWidth, isCode: { [weak self] in self?.isCode(at: $0) ?? true })
        else { return NSSound.beep() }
        // A caret inside would open the fold again at once, so it waits in front of it.
        for pane in panes {
            let caret = pane.textView.selectedRange()
            if caret.location > range.location, caret.location < NSMaxRange(range) {
                pane.textView.setSelectedRange(NSRange(location: range.location, length: 0))
            }
        }
        setFolds((folds + [range]).sorted { $0.location < $1.location }, changed: [range])
    }

    /// Folds every block at the level the menu item carries: 1 for the outermost ones.
    @objc func foldLevel(_ sender: NSMenuItem) {
        let ranges = Folding.ranges(
            in: text, level: max(sender.tag, 1), tabWidth: style.tabWidth, isCode: { [weak self] in self?.isCode(at: $0) ?? true })
        guard !ranges.isEmpty else { return NSSound.beep() }
        // A caret inside a fold would open it again, so it waits in front of it.
        for pane in panes {
            let caret = pane.textView.selectedRange().location
            if let around = ranges.first(where: { caret > $0.location && caret < NSMaxRange($0) }) {
                pane.textView.setSelectedRange(NSRange(location: around.location, length: 0))
            }
        }
        setFolds(ranges, changed: folds + ranges)
    }

    /// Folds the block the caret is in: the one starting on its line, or else the nearest one
    /// above that reaches down to it.
    @objc func foldBlock(_ sender: Any?) {
        let caret = textView.selectedRange().location
        var line = text.lineRange(for: NSRange(location: caret, length: 0))
        let own = line.location
        var steps = 0
        while steps < 5000 {
            if fold(onLineAt: line.location) == nil,
                let range = Folding.range(in: text, lineStart: line.location, tabWidth: style.tabWidth, isCode: { [weak self] in self?.isCode(at: $0) ?? true }),
                line.location == own || NSMaxRange(range) >= caret {
                return toggleFold(atLine: line.location)
            }
            guard line.location > 0 else { break }
            line = text.lineRange(for: NSRange(location: line.location - 1, length: 0))
            steps += 1
        }
        NSSound.beep()
    }

    /// Opens the fold on the caret's line.
    @objc func unfoldBlock(_ sender: Any?) {
        let caret = textView.selectedRange().location
        guard let existing = fold(onLineAt: caret) else { return NSSound.beep() }
        setFolds(folds.filter { $0 != existing }, changed: [existing])
    }

    @objc func unfoldAll(_ sender: Any?) {
        setFolds([], changed: folds)
    }

    // MARK: Table

    var isShowingTable: Bool { tableView != nil }

    private var isDelimitedFile: Bool {
        ["csv", "tsv", "tab", "psv"].contains(doc?.fileURL?.pathExtension.lowercased() ?? "")
    }

    /// Shows a CSV file as a table instead of text, or goes back to the text.
    @objc func toggleTable(_ sender: Any?) {
        if tableView != nil {
            hideTable()
        } else {
            if panes.count > 1 { toggleSplit(nil) }
            findBarClose()
            showTable()
        }
    }

    /// Reads the text as a table off the main thread and puts the table where the text was.
    private func showTable() {
        guard let doc else { return }
        let source = doc.textStorage.string
        workQueue.async { [weak self] in
            let table = DelimitedTable(source, maxRows: 200_000)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.doc != nil else { return }
                let view = self.tableView ?? DelimitedTableView()
                view.onOpen = { [weak self] offset in self?.hideTable(goingTo: offset) }
                view.onCount = { [weak self] shown, all in
                    var label = shown == all ? Self.count(all, "row") : "\(shown.formatted()) of \(Self.count(all, "row"))"
                    label += ", \(Self.count(table.columnCount, "column"))"
                    if !table.isComplete { label += ", the first 200,000 lines" }
                    self?.statusBar.setPosition(label)
                }
                view.show(table)
                if self.tableView == nil {
                    self.tableView = view
                    self.fillEditorArea(with: view)
                    self.window?.makeFirstResponder(view.table)
                }
            }
        }
    }

    /// Puts the keyboard in the table's filter field.
    func focusTableFilter() {
        tableView?.focusFilter()
    }

    /// Shows one view where the text is.
    private func fillEditorArea(with view: NSView) {
        NSLayoutConstraint.deactivate(paneConstraints)
        editorArea.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        editorArea.addSubview(view)
        paneConstraints = [
            view.leadingAnchor.constraint(equalTo: editorArea.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: editorArea.trailingAnchor),
            view.topAnchor.constraint(equalTo: editorArea.topAnchor),
            view.bottomAnchor.constraint(equalTo: editorArea.bottomAnchor),
        ]
        NSLayoutConstraint.activate(paneConstraints)
    }

    // MARK: Binary files

    /// Shows the bytes of a file that isn't text, or goes back to the text when the document
    /// has been read as text after all.
    private func updateHexView() {
        guard let data = doc?.binaryData else {
            guard hexView != nil else { return }
            hexView = nil
            layoutPanes()
            updateEditable()
            window?.makeFirstResponder(textView)
            return
        }
        let view = hexView ?? HexView()
        view.setFontSize(style.fontSize)
        // Not on every change of format, or the view would jump back to the top.
        if hexView == nil || shownRead != doc?.readCount { view.data = data }
        shownRead = doc?.readCount ?? 0
        if hexView == nil {
            if panes.count > 1 { toggleSplit(nil) }
            tableView = nil
            hexView = view
            fillEditorArea(with: view)
            updateEditable()
        }
        updatePosition()
    }

    /// Back to the text, at the given place when a row was opened.
    private func hideTable(goingTo offset: Int? = nil) {
        guard tableView != nil else { return }
        tableView = nil
        layoutPanes()
        window?.makeFirstResponder(textView)
        if let offset {
            let caret = NSRange(location: min(offset, text.length), length: 0)
            textView.setSelectedRange(caret)
            textView.scrollRangeToVisible(caret)
        }
        updatePosition()
    }

    // MARK: Bookmarks

    private func bookmarkedLines() -> Set<Int> {
        guard let index = doc?.lineIndex else { return [] }
        return Set(bookmarks.map { index.line(at: min($0, text.length)) })
    }

    /// Marks the line the caret is on, or takes its mark away.
    @objc func toggleBookmark(_ sender: Any?) {
        guard let index = doc?.lineIndex else { return }
        let line = index.line(at: textView.selectedRange().location)
        let before = bookmarks.count
        bookmarks.removeAll { index.line(at: min($0, text.length)) == line }
        if bookmarks.count == before { bookmarks.append(index.start(ofLine: line)) }
        for pane in panes { pane.gutter.needsDisplay = true }
    }

    @objc func nextBookmark(_ sender: Any?) { goToBookmark(forward: true) }
    @objc func previousBookmark(_ sender: Any?) { goToBookmark(forward: false) }

    /// The nearest bookmarked line after or before the caret, going round at the ends.
    private func goToBookmark(forward: Bool) {
        guard let index = doc?.lineIndex else { return }
        let lines = bookmarkedLines().sorted()
        let current = index.line(at: textView.selectedRange().location)
        let target = forward ? lines.first { $0 > current } ?? lines.first : lines.last { $0 < current } ?? lines.last
        guard let target else { return NSSound.beep() }
        go(toLine: target + 1)
    }

    @objc func clearBookmarks(_ sender: Any?) {
        bookmarks = []
        for pane in panes { pane.gutter.needsDisplay = true }
    }

    // MARK: Title

    /// The arrow beside the title opens a panel to rename, tag and move the file. A document
    /// that was never saved has no file, so it gets no arrow, and no "— Edited" either, which
    /// the same button writes.
    func updateTitleButton() {
        guard let button = window?.standardWindowButton(.documentVersionsButton) else { return }
        let hide = doc?.fileURL == nil
        button.isHidden = hide
        // The dash between the title and "Edited" is a label of its own beside the button. It
        // comes back only while the button has something to say.
        for case let label as NSTextField in button.superview?.subviews ?? [] where label.stringValue == "—" {
            label.isHidden = hide || button.title.isEmpty
        }
    }

    override func synchronizeWindowTitleWithDocumentName() {
        super.synchronizeWindowTitleWithDocumentName()
        updateTitleButton()
    }

    /// Two open files with the same name get their folder beside the name, in the tab too.
    override func windowTitle(forDocumentDisplayName displayName: String) -> String {
        guard let doc, let folder = doc.fileURL?.deletingLastPathComponent().lastPathComponent else { return displayName }
        let twin = NSDocumentController.shared.documents.contains { $0 !== doc && $0.displayName == displayName }
        return twin ? "\(displayName) — \(folder)" : displayName
    }

    /// Moves the caret to the end of the text and shows it, for a file that grows on disk.
    func followEnd() {
        let end = NSRange(location: text.length, length: 0)
        activeView.setSelectedRange(end)
        activeView.scrollRangeToVisible(end)
    }

    /// The colours of the text for printing, when the whole text has been scanned.
    var printableTokens: [Token] { tokensAreValid ? tokens : [] }

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

    /// Makes the next key typed start a new undo step. See `Document.save`.
    func breakUndoCoalescing() {
        for pane in panes { pane.textView.breakUndoCoalescing() }
    }

    func windowWillClose(_ notification: Notification) {
        // Here and not in the document's `close`, which runs once the window has let go of it.
        savePosition()
    }

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
