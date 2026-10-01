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

/// One document's window (or tab): the text view, line numbers, find bar and status bar.
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    /// Above this many UTF-16 units a file is shown without colours.
    static let highlightLimit = 4_000_000
    /// A scan that takes longer than this many seconds is abandoned and colours are turned off.
    static let highlightTimeout = 5.0
    /// Above this, background work waits for a pause in typing.
    static let debounceLimit = 400_000

    let textView: EditorTextView
    let findBar = FindBar()
    let resultsView = FindResultsView()
    private let layoutManager = EditorLayoutManager()
    private let scrollView = NSScrollView()
    private let gutter = GutterView()
    private let statusBar = StatusBar()
    private var gutterWidth: NSLayoutConstraint!
    private var style = EditorStyle.current

    private var tokens: [Token] = []
    private let tokenGeneration = Generation()
    private var decorated = NSRange(location: 0, length: 0)
    private var editPending = false
    /// Set when the syntax proved too slow for this text; cleared when the syntax changes.
    private var highlightTimedOut = false

    // Find state; the logic is in EditorFind.swift.
    var matches: [NSRange] = []
    var matchesAreCurrent = false
    var selectionScope: NSRange?
    var findMessage: String?
    let findGeneration = Generation()

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
    var text: NSMutableString { textView.textStorage!.mutableString }

    init(document: Document) {
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.allowsNonContiguousLayout = true
        layoutManager.addTextContainer(container)
        document.textStorage.addLayoutManager(layoutManager)
        textView = EditorTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 500), textContainer: container)

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

        configureTextView()
        buildLayout(in: window)
        gutter.textView = textView
        gutter.lineIndex = { [weak document] in document?.lineIndex ?? LineIndex() }
        statusBar.editor = self
        findBar.delegate = self
        resultsView.onSelect = { [weak self] in self?.reveal($0) }
        resultsView.onClose = { [weak self] in self?.resultsView.isHidden = true }

        let center = NotificationCenter.default
        scrollView.contentView.postsBoundsChangedNotifications = true
        textView.postsFrameChangedNotifications = true
        center.addObserver(
            self, selector: #selector(viewportChanged), name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView)
        center.addObserver(
            self, selector: #selector(viewportChanged), name: NSView.frameDidChangeNotification, object: textView)
        center.addObserver(self, selector: #selector(syntaxChanged), name: Document.syntaxDidChange, object: document)
        center.addObserver(self, selector: #selector(formatChanged), name: Document.formatDidChange, object: document)
        center.addObserver(self, selector: #selector(formatChanged), name: SyntaxStore.didChange, object: nil)
        center.addObserver(
            self, selector: #selector(defaultsChanged), name: UserDefaults.didChangeNotification, object: nil)

        apply(style, initial: true)
        adoptSyntax(of: document)
        statusBar.update()
        updatePosition()
        window.makeFirstResponder(textView)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Setup

    private func configureTextView() {
        textView.delegate = self
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFontPanel = false
        textView.usesFindBar = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.backgroundColor = Theme.background
        textView.insertionPointColor = Theme.text
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    }

    private func buildLayout(in window: NSWindow) {
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = Theme.background

        let editorRow = NSView()
        for view in [gutter, scrollView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            editorRow.addSubview(view)
        }
        gutterWidth = gutter.widthAnchor.constraint(equalToConstant: 40)
        NSLayoutConstraint.activate([
            gutterWidth,
            gutter.leadingAnchor.constraint(equalTo: editorRow.leadingAnchor),
            gutter.topAnchor.constraint(equalTo: editorRow.topAnchor),
            gutter.bottomAnchor.constraint(equalTo: editorRow.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: gutter.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: editorRow.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: editorRow.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: editorRow.bottomAnchor),
        ])

        findBar.isHidden = true
        resultsView.isHidden = true
        let stack = NSStackView(views: [findBar, editorRow, resultsView, statusBar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        editorRow.setContentHuggingPriority(.defaultLow, for: .vertical)

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

    // MARK: Settings

    @objc private func defaultsChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let new = EditorStyle.current
            if new != self.style { self.apply(new, initial: false) }
        }
    }

    private func apply(_ new: EditorStyle, initial: Bool) {
        let old = style
        style = new
        textView.style = new

        if initial || old.fontName != new.fontName || old.fontSize != new.fontSize || old.tabWidth != new.tabWidth {
            let attributes = new.textAttributes
            if !initial, let storage = textView.textStorage {
                storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
            }
            textView.typingAttributes = attributes
            layoutManager.invisiblesFont = new.font
            gutter.font = .monospacedDigitSystemFont(ofSize: max(9, CGFloat(new.fontSize) - 2), weight: .regular)
        }
        if initial || old.wrapLines != new.wrapLines {
            applyWrap(new.wrapLines)
        }
        gutter.isHidden = !new.lineNumbers
        updateGutterWidth()
        layoutManager.showsInvisibles = new.showInvisibles
        decorated.length = 0
        textView.needsDisplay = true
        gutter.needsDisplay = true
        decorateVisible()
    }

    private func applyWrap(_ wrap: Bool) {
        guard let container = textView.textContainer else { return }
        let width = scrollView.contentSize.width
        scrollView.hasHorizontalScroller = !wrap
        textView.isHorizontallyResizable = !wrap
        if wrap {
            textView.autoresizingMask = [.width]
            container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            container.widthTracksTextView = true
            textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
        } else {
            textView.autoresizingMask = [.width, .height]
            container.widthTracksTextView = false
            container.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
        textView.sizeToFit()
    }

    private func updateGutterWidth() {
        let width = style.lineNumbers ? gutter.width(forLineCount: doc?.lineIndex.count ?? 1) : 0
        if gutterWidth.constant != width { gutterWidth.constant = width }
    }

    // MARK: Syntax colours

    @objc private func syntaxChanged() {
        guard let doc else { return }
        adoptSyntax(of: doc)
        statusBar.update()
    }

    private func adoptSyntax(of document: Document) {
        let definition = document.syntax?.definition
        textView.lineComment = definition?.lineComment
        textView.blockComment = definition?.blockComment
        textView.indentWithTabs = definition?.indentWithTabs == true
        textView.indentAfterColon = definition?.indentAfterColon == true
        tokens = []
        highlightTimedOut = false
        layoutManager.removeTemporaryAttribute(
            .foregroundColor, forCharacterRange: NSRange(location: 0, length: document.textStorage.length))
        decorated.length = 0
        scheduleHighlight(of: document)
    }

    private func scheduleHighlight(of document: Document) {
        let generation = tokenGeneration.next()
        let length = document.textStorage.length
        guard let syntax = document.syntax, !highlightTimedOut, length > 0, length <= Self.highlightLimit else {
            if !tokens.isEmpty {
                tokens = []
                decorateVisible(force: true)
            }
            return
        }
        let delay = length > Self.debounceLimit ? 0.2 : 0
        after(delay) { [weak self, weak document] in
            guard let self, let document, self.tokenGeneration.isCurrent(generation) else { return }
            let snapshot = Unchecked(value: document.textStorage.mutableString.copy() as! NSString)
            self.workQueue.async {
                let deadline = Date().addingTimeInterval(Self.highlightTimeout)
                var timedOut = false
                var tokens = syntax.tokenize(snapshot.value) {
                    timedOut = Date() > deadline
                    return timedOut || !self.tokenGeneration.isCurrent(generation)
                }
                if timedOut { tokens = [] }
                let gaveUp = timedOut
                DispatchQueue.main.async {
                    guard self.tokenGeneration.isCurrent(generation) else { return }
                    self.highlightTimedOut = gaveUp
                    self.tokens = tokens
                    self.decorateVisible(force: true)
                }
            }
        }
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

    /// Colours the text on screen, plus a margin so short scrolls need no work.
    /// Only that part gets attributes, which keeps large files cheap.
    func decorateVisible(force: Bool = false) {
        guard let container = textView.textContainer else { return }
        let visible = textView.visibleRect
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let onScreen = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        if !force, decorated.length > 0, onScreen.location >= decorated.location,
            NSMaxRange(onScreen) <= NSMaxRange(decorated) {
            return
        }
        let padded = visible.insetBy(dx: 0, dy: -visible.height)
        let range = layoutManager.characterRange(
            forGlyphRange: layoutManager.glyphRange(forBoundingRect: padded, in: container), actualGlyphRange: nil)
        decorated = range

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

    // MARK: Edits and scrolling

    /// Called by the document while the text storage is still processing the edit,
    /// so this only fixes up offsets; the visible work happens right after.
    func textDidEdit(newRange: NSRange, delta: Int) {
        let oldEnd = newRange.location + newRange.length - delta
        var index = Self.firstIndex(in: tokens, endingAfter: newRange.location) { $0.range }
        while index < tokens.count {
            if tokens[index].range.location >= oldEnd {
                tokens[index].range.location += delta
            } else {
                // A token touched by the edit stretches with it until the next scan.
                tokens[index].range.length = max(0, tokens[index].range.length + delta)
            }
            index += 1
        }
        matchesAreCurrent = false
        index = Self.firstIndex(in: matches, endingAfter: newRange.location) { $0 }
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
            self.decorated.length = 0
            self.updateGutterWidth()
            self.gutter.needsDisplay = true
            self.scheduleHighlight(of: doc)
            self.refreshMatches()
            self.updatePosition()
        }
    }

    @objc private func viewportChanged() {
        gutter.needsDisplay = true
        decorateVisible()
    }

    @objc private func formatChanged() {
        statusBar.update()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        textView.updateCurrentLine()
        gutter.needsDisplay = true
        updatePosition()
        if !findBar.isHidden { updateFindStatus() }
    }

    private func updatePosition() {
        guard let index = doc?.lineIndex else { return }
        let selection = textView.selectedRange()
        let line = index.line(at: selection.location)
        var label = "Line \(line + 1), Column \(selection.location - index.start(ofLine: line) + 1)"
        if selection.length > 0 {
            let lines = index.line(at: NSMaxRange(selection)) - line + 1
            label += lines > 1 ? "  (\(selection.length) characters, \(lines) lines selected)"
                : "  (\(selection.length) selected)"
        }
        statusBar.setPosition(label)
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
        if defaults.bool(forKey: Prefs.trimTrailingWhitespace),
            let query = try? SearchQuery(pattern: "[ \\t]+$", options: SearchOptions(regex: true)),
            let result = query.replaceAll(in: text, with: Replacement(template: "", isRegex: false)) {
            let caret = textView.selectedRange().location
            textView.replace(result.range, with: result.text)
            textView.setSelectedRange(NSRange(location: min(caret, text.length), length: 0))
        }
        if defaults.bool(forKey: Prefs.ensureFinalNewline), text.length > 0,
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
            guard let self, response == .alertFirstButtonReturn, let index = self.doc?.lineIndex else { return }
            let parts = field.stringValue.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            guard let line = parts.first, line >= 1 else { return }
            let target = min(line, index.count) - 1
            let start = index.start(ofLine: target)
            let lineEnd = target + 1 < index.count ? index.start(ofLine: target + 1) - 1 : self.text.length
            let column = parts.count > 1 ? max(parts[1], 1) - 1 : 0
            let range = NSRange(location: min(start + column, lineEnd), length: 0)
            self.textView.setSelectedRange(range)
            self.textView.scrollRangeToVisible(range)
            self.window?.makeFirstResponder(self.textView)
        }
    }
}
