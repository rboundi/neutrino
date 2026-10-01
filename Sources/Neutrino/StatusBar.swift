import AppKit
import NeutrinoCore

/// The strip under the text: caret position, syntax, line endings and encoding.
final class StatusBar: NSView, NSMenuDelegate {
    weak var editor: EditorWindowController?

    private let position = NSTextField(labelWithString: "")
    private let syntax = StatusBar.popup()
    private let lineEnding = StatusBar.popup()
    private let encoding = StatusBar.popup()

    override init(frame: NSRect) {
        super.init(frame: frame)
        position.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        position.textColor = .secondaryLabelColor
        position.translatesAutoresizingMaskIntoConstraints = false
        syntax.toolTip = "Syntax"
        lineEnding.toolTip = "Line endings"
        encoding.toolTip = "Encoding"

        let popups = NSStackView(views: [syntax, lineEnding, encoding])
        popups.orientation = .horizontal
        popups.spacing = 4
        popups.translatesAutoresizingMaskIntoConstraints = false
        for popup in [syntax, lineEnding, encoding] {
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

    func setPosition(_ text: String) {
        position.stringValue = text
    }

    /// Shows the document's current syntax, line endings and encoding.
    func update() {
        guard let document = editor?.doc else { return }
        syntax.item(at: 0)?.title = document.syntax?.definition.name ?? "Plain Text"
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

        if menu === syntax.menu {
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

    @objc private func pickSyntax(_ sender: NSMenuItem) {
        editor?.doc?.setSyntax(id: sender.representedObject as? String)
    }

    @objc private func installSyntax(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
            let info = SyntaxStore.shared.catalog.first(where: { $0.id == id })
        else { return }
        SyntaxStore.shared.install(info) { error in
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
