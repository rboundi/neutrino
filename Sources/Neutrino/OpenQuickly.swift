import AppKit

/// A small panel for jumping to an open document or a recent file by typing part of its name.
final class OpenQuickly: NSObject, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    static let shared = OpenQuickly()

    private struct Item {
        var name: String
        var detail: String
        /// Weak, so the list doesn't keep a document open after its tab is closed.
        weak var document: NSDocument?
        var url: URL?
    }

    private let panel: NSPanel
    private let field = NSSearchField()
    private let table = NSTableView()
    private var all: [Item] = []
    private var shown: [Item] = []

    private override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
        super.init()
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = true
        panel.delegate = self

        field.placeholderString = "Open a tab or a recent file"
        field.font = .systemFont(ofSize: 15)
        field.controlSize = .large
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 34
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.refusesFirstResponder = true

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(field)
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        panel.contentView = content
    }

    func show() {
        let controller = NSDocumentController.shared
        let current = controller.currentDocument
        // Open documents first, the one in front last of them, then recent files that aren't open.
        var documents = controller.documents.filter { $0 !== current }
        if let current { documents.append(current) }
        let open = Set(documents.compactMap { $0.fileURL?.standardizedFileURL })
        all = documents.map {
            Item(name: $0.displayName ?? "Untitled", detail: Self.folder(of: $0.fileURL) ?? "Not saved", document: $0)
        }
        all += controller.recentDocumentURLs.filter { !open.contains($0.standardizedFileURL) }.map {
            Item(name: $0.lastPathComponent, detail: Self.folder(of: $0) ?? "", url: $0)
        }
        field.stringValue = ""
        filter()
        if let window = NSApp.mainWindow {
            let frame = window.frame
            panel.setFrameTopLeftPoint(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.maxY - 90))
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    private static func folder(of url: URL?) -> String? {
        url.map { ($0.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath }
    }

    /// How well a name fits what was typed: 0 for a name that starts with it, then a name that
    /// contains it, then one with its letters in order; nil for no fit.
    private static func rank(_ name: String, _ query: String) -> Int? {
        if name.hasPrefix(query) { return 0 }
        if name.contains(query) { return 1 }
        var rest = name[...]
        for letter in query {
            guard let found = rest.firstIndex(of: letter) else { return nil }
            rest = rest[rest.index(after: found)...]
        }
        return 2
    }

    private func filter() {
        let query = field.stringValue.lowercased().filter { !$0.isWhitespace }
        if query.isEmpty {
            shown = all
        } else {
            shown = all.enumerated()
                .compactMap { index, item in Self.rank(item.name.lowercased(), query).map { (rank: $0, index: index, item: item) } }
                .sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }
                .map(\.item)
        }
        table.reloadData()
        if !shown.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    @objc private func openSelected() {
        guard shown.indices.contains(table.selectedRow) else { return NSSound.beep() }
        let item = shown[table.selectedRow]
        panel.orderOut(nil)
        if let document = item.document {
            document.showWindows()
        } else if let url = item.url {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        }
    }

    private func move(by step: Int) {
        guard !shown.isEmpty else { return }
        let row = min(max(table.selectedRow + step, 0), shown.count - 1)
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    // MARK: Field and table

    func controlTextDidChange(_ notification: Notification) {
        filter()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(by: 1)
        case #selector(NSResponder.moveUp(_:)): move(by: -1)
        case #selector(NSResponder.insertNewline(_:)): openSelected()
        case #selector(NSResponder.cancelOperation(_:)): panel.orderOut(nil)
        default: return false
        }
        return true
    }

    func windowDidResignKey(_ notification: Notification) {
        panel.orderOut(nil)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        shown.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField
            ?? {
                let cell = NSTextField(labelWithString: "")
                cell.identifier = identifier
                cell.lineBreakMode = .byTruncatingMiddle
                cell.maximumNumberOfLines = 2
                return cell
            }()
        let item = shown[row]
        let text = NSMutableAttributedString(string: item.name, attributes: [.font: NSFont.systemFont(ofSize: 13)])
        text.append(NSAttributedString(
            string: "\n" + item.detail,
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        cell.attributedStringValue = text
        return cell
    }
}
