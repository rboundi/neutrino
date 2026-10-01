import AppKit
import NeutrinoCore

/// The strip under the text: caret position, syntax, line endings and encoding.
final class StatusBar: NSView, NSMenuDelegate {
    weak var editor: EditorWindowController?

    /// The line and column, as a button: a click shows the size of the document.
    private let position = NSButton(title: "", target: nil, action: nil)
    private let sizeLabel = NSTextField(labelWithString: "")
    private lazy var lock = symbolButton("lock.open", "", #selector(toggleLock))
    private let symbols = StatusBar.popup()
    private var symbolList: [Symbol] = []
    private let syntax = StatusBar.popup()
    private let lineEnding = StatusBar.popup()
    private let encoding = StatusBar.popup()

    override init(frame: NSRect) {
        super.init(frame: frame)
        position.isBordered = false
        position.target = self
        position.action = #selector(showCounts)
        position.lineBreakMode = .byTruncatingTail
        position.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        position.translatesAutoresizingMaskIntoConstraints = false
        position.toolTip = "Click to count the lines, words and characters in the document"
        syntax.toolTip = "Syntax"
        lineEnding.toolTip = "Line endings"
        encoding.toolTip = "Encoding"

        symbols.toolTip = "Symbols"
        symbols.item(at: 0)?.title = "Symbols"
        // Text size: the size in points with a minus and a plus beside it. The size chosen becomes
        // the default.
        let smaller = sizeButton("minus", "Smaller text", -1)
        let larger = sizeButton("plus", "Larger text", 1)
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        sizeLabel.toolTip = "Text size. It is used for every document from now on."
        let size = NSStackView(views: [smaller, sizeLabel, larger])
        size.orientation = .horizontal
        size.spacing = 1

        let popups = NSStackView(views: [lock, size, symbols, syntax, lineEnding, encoding])
        popups.setCustomSpacing(6, after: lock)
        popups.setCustomSpacing(10, after: size)
        popups.orientation = .horizontal
        popups.spacing = 4
        popups.translatesAutoresizingMaskIntoConstraints = false
        for popup in [symbols, syntax, lineEnding, encoding] {
            popup.menu?.delegate = self
        }

        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false

        addSubview(position)
        addSubview(popups)
        addSubview(line)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            line.topAnchor.constraint(equalTo: topAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            position.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            position.centerYAnchor.constraint(equalTo: centerYAnchor),
            popups.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            popups.centerYAnchor.constraint(equalTo: centerYAnchor),
            popups.leadingAnchor.constraint(greaterThanOrEqualTo: position.trailingAnchor, constant: 8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func popup() -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: true)
        popup.isBordered = false
        popup.controlSize = .small
        popup.font = .systemFont(ofSize: 11)
        popup.addItem(withTitle: "")
        popup.setContentHuggingPriority(.required, for: .horizontal)
        return popup
    }

    /// A small borderless symbol with a click area as tall as the bar, so it is easy to hit.
    private func sizeButton(_ symbol: String, _ label: String, _ step: Int) -> NSButton {
        let button = symbolButton(symbol, label, #selector(changeSize(_:)))
        button.tag = step
        return button
    }

    private static func image(_ symbol: String, _ label: String) -> NSImage {
        NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)) ?? NSImage()
    }

    private func symbolButton(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let button = NSButton(image: Self.image(symbol, label), target: self, action: action)
        button.isBordered = false
        // The same colour as the menus beside it; a grey symbol reads as switched off.
        button.contentTintColor = .labelColor
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 20),
            button.heightAnchor.constraint(equalToConstant: 22),
        ])
        return button
    }

    @objc private func toggleLock() {
        editor?.toggleLock(nil)
    }

    @objc private func showCounts() {
        editor?.showDocumentCounts()
    }

    @objc private func changeSize(_ sender: NSButton) {
        Prefs.changeFontSize(by: Double(sender.tag))
    }

    func setPosition(_ text: String) {
        position.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }

    /// Shows the document's current syntax, line endings and encoding.
    func update() {
        sizeLabel.stringValue = "\(Int(EditorStyle.current.fontSize)) pt"
        let locked = editor?.isLocked == true
        let label = locked ? "Read-only. Click to allow editing." : "Click to make the document read-only."
        lock.image = Self.image(locked ? "lock.fill" : "lock.open", label)
        lock.toolTip = label
        lock.setAccessibilityLabel(locked ? "Locked" : "Unlocked")
        guard let document = editor?.doc else { return }
        syntax.item(at: 0)?.title = document.syntax?.definition.name ?? "Plain Text"
        symbols.isHidden = document.syntax?.definition.symbols?.isEmpty ?? true

        lineEnding.item(at: 0)?.title = document.lineEnding.label
        encoding.item(at: 0)?.title = TextCodec.name(of: document.encoding)
    }

    // MARK: Menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let document = editor?.doc else { return }
        while menu.numberOfItems > 1 { menu.removeItem(at: 1) }

        func add(_ title: String, _ action: Selector, _ value: Any?, on: Bool = false, to target: NSMenu = menu) {
            let item = target.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = on ? .on : .off
        }

        if menu === symbols.menu {
            symbolList = Array((editor?.symbols() ?? []).prefix(1500))
            let text = editor?.text
            for (index, symbol) in symbolList.enumerated() {
                let item = menu.addItem(withTitle: symbol.name, action: #selector(pickSymbol(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                // Indented like the line it is on, so methods sit under their class.
                if let text {
                    let line = text.lineRange(for: NSRange(location: symbol.range.location, length: 0))
                    var column = 0
                    while column < line.length, [0x20, 0x09].contains(text.character(at: line.location + column)) {
                        column += text.character(at: line.location + column) == 0x09 ? 4 : 1
                    }
                    item.indentationLevel = min(column / 2, 8)
                }
            }
            if symbolList.isEmpty {
                menu.addItem(withTitle: "No Symbols", action: nil, keyEquivalent: "").isEnabled = false
            }
        } else if menu === syntax.menu {
            let current = document.syntax?.definition.id
            add("Plain Text", #selector(pickSyntax(_:)), nil, on: current == nil)
            let installed = SyntaxStore.shared.installed
            if !installed.isEmpty { menu.addItem(.separator()) }
            for info in installed {
                add(info.name, #selector(pickSyntax(_:)), info.id, on: info.id == current)
            }
            menu.addItem(.separator())
            if let suggestion = document.suggestedSyntax {
                add("Install \(suggestion.name) Syntax", #selector(installSyntax(_:)), suggestion.id)
            }
            add("More Syntaxes…", #selector(showSyntaxSettings), nil)
        } else if menu === lineEnding.menu {
            for ending in LineEnding.allCases {
                let names = [LineEnding.lf: "LF (macOS, Unix)", .crlf: "CRLF (Windows)", .cr: "CR (Classic Mac OS)"]
                add(names[ending]!, #selector(pickLineEnding(_:)), ending.rawValue, on: ending == document.lineEnding)
            }
        } else {
            for (name, value) in TextCodec.encodings {
                add(name, #selector(pickEncoding(_:)), value.rawValue, on: value == document.encoding)
            }
            if document.fileURL != nil {
                menu.addItem(.separator())
                let reopen = menu.addItem(withTitle: "Reopen with Encoding", action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                for (name, value) in TextCodec.encodings {
                    add(name, #selector(reopen(_:)), value.rawValue, to: submenu)
                }
                reopen.submenu = submenu
            }
        }
    }

    func openSymbols() {
        guard !symbols.isHidden else { return NSSound.beep() }
        symbols.performClick(nil)
    }

    @objc private func pickSymbol(_ sender: NSMenuItem) {
        guard symbolList.indices.contains(sender.tag) else { return }
        editor?.reveal(symbolList[sender.tag])
    }

    @objc private func pickSyntax(_ sender: NSMenuItem) {
        editor?.doc?.setSyntax(id: sender.representedObject as? String)
    }

    @objc private func installSyntax(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
            let info = SyntaxStore.shared.catalog.first(where: { $0.id == id })
        else { return }
        SyntaxStore.shared.files.install(id: info.id) { error in
            guard let error else { return }
            let alert = NSAlert()
            alert.messageText = "Couldn't install the \(info.name) syntax"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func showSyntaxSettings() {
        SettingsWindowController.shared.show(tab: .syntaxes)
    }

    @objc private func pickLineEnding(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let ending = LineEnding(rawValue: raw) else { return }
        editor?.doc?.setLineEnding(ending)
    }

    @objc private func pickEncoding(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? UInt else { return }
        editor?.doc?.setEncoding(String.Encoding(rawValue: raw))
    }

    @objc private func reopen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? UInt, let document = editor?.doc else { return }
        if document.isDocumentEdited {
            let alert = NSAlert()
            alert.messageText = "Reopen and lose unsaved changes?"
            alert.addButton(withTitle: "Reopen")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        document.reopen(as: String.Encoding(rawValue: raw))
    }
}
