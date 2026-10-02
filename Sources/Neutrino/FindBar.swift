import AppKit
import NeutrinoCore

enum FindScope: Int {
    case document, selection, allDocuments
}

protocol FindBarDelegate: AnyObject {
    func findBarChanged()
    func findBarScopeChanged()
    func findBarNext(backwards: Bool)
    func findBarReplace()
    func findBarReplaceAll()
    func findBarFindAll()
    func findBarClose()
}

/// The find and replace strip above the text.
final class FindBar: NSView, NSSearchFieldDelegate {
    weak var delegate: FindBarDelegate?

    let findField = NSSearchField()
    private let replaceField = NSTextField()
    private let status = NSTextField(labelWithString: "")
    private let scopePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private lazy var regexButton = toggle(".*", tip: "Regular expression", key: Prefs.findRegex)
    private lazy var caseButton = toggle("Aa", tip: "Match case", key: Prefs.findCaseSensitive)
    private lazy var wordButton = toggle("W", tip: "Whole words", key: Prefs.findWholeWord)

    var pattern: String {
        get { findField.stringValue }
        set {
            findField.stringValue = newValue
            reported = newValue
        }
    }
    /// The pattern the delegate last heard about. Typing reaches the bar twice, as the field's
    /// action and as a text change, and one search per key is enough.
    private var reported = ""

    var replacement: String {
        get { replaceField.stringValue }
        set { replaceField.stringValue = newValue }
    }

    var options: SearchOptions {
        SearchOptions(
            regex: regexButton.state == .on, caseSensitive: caseButton.state == .on,
            wholeWord: wordButton.state == .on)
    }

    var scope: FindScope {
        get { FindScope(rawValue: scopePopup.indexOfSelectedItem) ?? .document }
        set { scopePopup.selectItem(at: newValue.rawValue) }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)

        findField.placeholderString = "Find"
        findField.delegate = self
        findField.sendsWholeSearchString = false
        findField.sendsSearchStringImmediately = true
        findField.target = self
        findField.action = #selector(changed)
        findField.recentsAutosaveName = Prefs.findHistory
        findField.maximumRecents = 15
        findField.searchMenuTemplate = Self.recentsMenu()
        findField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)

        replaceField.placeholderString = "Replace"
        replaceField.delegate = self
        replaceField.font = findField.font
        replaceField.lineBreakMode = .byTruncatingTail
        replaceField.usesSingleLineMode = true
        replaceField.bezelStyle = .roundedBezel
        replaceField.toolTip =
            "With regular expressions on: $1 or \\1 for groups, ${name}, $0 for the match, "
            + "\\U…\\E upper case, \\L…\\E lower case, \\u and \\l for one character, \\n and \\t."

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        scopePopup.addItems(withTitles: ["Document", "Selection", "All Open Documents"])
        scopePopup.controlSize = .small
        scopePopup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        scopePopup.target = self
        scopePopup.action = #selector(scopeChanged)
        scopePopup.toolTip = "Where to search and replace"

        let arrows = NSSegmentedControl(
            images: [
                NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Previous")!,
                NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Next")!,
            ], trackingMode: .momentary, target: self, action: #selector(step(_:)))
        arrows.controlSize = .small

        let first = row([
            findField, regexButton, caseButton, wordButton, arrows,
            button("Find All", #selector(findAll)), button("Done", #selector(close)),
        ])
        let second = row([
            replaceField, scopePopup, button("Replace", #selector(replace)),
            button("Replace All", #selector(replaceAll)), status,
        ])
        let stack = NSStackView(views: [first, second])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 10, bottom: 7, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        addSubview(line)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            first.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
            second.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
            replaceField.widthAnchor.constraint(equalTo: findField.widthAnchor),
            findField.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Options are shared by every window, so read them again when the bar is shown.
    func syncOptions() {
        let defaults = UserDefaults.standard
        regexButton.state = defaults.bool(forKey: Prefs.findRegex) ? .on : .off
        caseButton.state = defaults.bool(forKey: Prefs.findCaseSensitive) ? .on : .off
        wordButton.state = defaults.bool(forKey: Prefs.findWholeWord) ? .on : .off
    }

    func setStatus(_ text: String, isError: Bool = false) {
        status.stringValue = text
        status.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    /// Adds the current pattern to the recent searches.
    func remember() {
        let pattern = self.pattern
        guard !pattern.isEmpty else { return }
        var recents = findField.recentSearches.filter { $0 != pattern }
        recents.insert(pattern, at: 0)
        findField.recentSearches = Array(recents.prefix(15))
    }

    // MARK: Building

    private func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 6
        return row
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    private func toggle(_ title: String, tip: String, key: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(optionChanged(_:)))
        button.setButtonType(.pushOnPushOff)
        button.bezelStyle = .recessed
        button.controlSize = .small
        button.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        button.toolTip = tip
        button.identifier = NSUserInterfaceItemIdentifier(key)
        button.state = UserDefaults.standard.bool(forKey: key) ? .on : .off
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    private static func recentsMenu() -> NSMenu {
        let menu = NSMenu()
        let title = menu.addItem(withTitle: "Recent Searches", action: nil, keyEquivalent: "")
        title.tag = NSSearchField.recentsTitleMenuItemTag
        let recents = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        recents.tag = NSSearchField.recentsMenuItemTag
        menu.addItem(.separator())
        let clear = menu.addItem(withTitle: "Clear", action: nil, keyEquivalent: "")
        clear.tag = NSSearchField.clearRecentsMenuItemTag
        return menu
    }

    // MARK: Actions

    @objc private func changed() {
        guard pattern != reported else { return }
        reported = pattern
        delegate?.findBarChanged()
    }
    @objc private func scopeChanged() { delegate?.findBarScopeChanged() }
    @objc private func findAll() { delegate?.findBarFindAll() }
    @objc private func close() { delegate?.findBarClose() }
    @objc private func replace() { delegate?.findBarReplace() }
    @objc private func replaceAll() { delegate?.findBarReplaceAll() }

    @objc private func step(_ sender: NSSegmentedControl) {
        delegate?.findBarNext(backwards: sender.selectedSegment == 0)
    }

    @objc private func optionChanged(_ sender: NSButton) {
        if let key = sender.identifier?.rawValue {
            UserDefaults.standard.set(sender.state == .on, forKey: key)
        }
        delegate?.findBarChanged()
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSSearchField === findField { changed() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if control === findField {
                let backwards = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
                delegate?.findBarNext(backwards: backwards)
            } else {
                delegate?.findBarReplace()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            delegate?.findBarClose()
            return true
        default:
            return false
        }
    }
}

struct FindResult {
    weak var document: Document?
    var range: NSRange
    var location: String
    var snippet: NSAttributedString
}

/// The list of matches from Find All, below the text.
final class FindResultsView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var onSelect: (FindResult) -> Void = { _ in }
    var onClose: () -> Void = {}

    private let table = NSTableView()
    private let title = NSTextField(labelWithString: "")
    private var results: [FindResult] = []
    /// Every matched string, for the Copy button.
    private var matched: [String] = []

    override init(frame: NSRect) {
        super.init(frame: frame)

        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.textColor = .secondaryLabelColor

        let copy = NSButton(title: "Copy Matches", target: self, action: #selector(copyMatches))
        let close = NSButton(title: "Close", target: self, action: #selector(closeList))
        for button in [copy, close] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }
        let header = NSStackView(views: [title, NSView(), copy, close])
        header.orientation = .horizontal
        header.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        header.translatesAutoresizingMaskIntoConstraints = false

        let location = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("location"))
        location.width = 170
        location.minWidth = 80
        let text = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("text"))
        text.resizingMask = .autoresizingMask
        table.addTableColumn(location)
        table.addTableColumn(text)
        table.headerView = nil
        table.rowHeight = 18
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false

        addSubview(line)
        addSubview(header)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: topAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: line.bottomAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 190),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ results: [FindResult], matched: [String], title: String) {
        self.results = results
        self.matched = matched
        self.title.stringValue = title
        table.reloadData()
        if !results.isEmpty { table.scrollRowToVisible(0) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        results.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn else { return nil }
        let field = tableView.makeView(withIdentifier: column.identifier, owner: nil) as? NSTextField
            ?? {
                let field = NSTextField(labelWithString: "")
                field.identifier = column.identifier
                field.lineBreakMode = .byTruncatingTail
                return field
            }()
        let result = results[row]
        if column.identifier.rawValue == "location" {
            field.font = .systemFont(ofSize: 11)
            field.textColor = .secondaryLabelColor
            field.stringValue = result.location
        } else {
            field.attributedStringValue = result.snippet
        }
        return field
    }

    @objc private func rowClicked() {
        guard results.indices.contains(table.clickedRow) else { return }
        onSelect(results[table.clickedRow])
    }

    @objc private func copyMatches() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(matched.joined(separator: "\n"), forType: .string)
    }

    @objc private func closeList() { onClose() }
}

/// A strip above the text with a message and a few buttons, for something that needs a decision.
final class NoticeBar: NSView {
    private let label = NSTextField(labelWithString: "")
    private let buttons = NSStackView()
    private var actions: [() -> Void] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        buttons.orientation = .horizontal
        buttons.spacing = 6
        let row = NSStackView(views: [label, NSView(), buttons])
        row.orientation = .horizontal
        row.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        addSubview(line)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemYellow.withAlphaComponent(0.18).setFill()
        bounds.fill()
    }

    func show(_ message: String, buttons titles: [(String, () -> Void)]) {
        label.stringValue = message
        actions = titles.map(\.1)
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, entry) in titles.enumerated() {
            let button = NSButton(title: entry.0, target: self, action: #selector(pressed(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            button.tag = index
            buttons.addArrangedSubview(button)
        }
        isHidden = false
    }

    @objc private func pressed(_ sender: NSButton) {
        if actions.indices.contains(sender.tag) { actions[sender.tag]() }
    }
}
