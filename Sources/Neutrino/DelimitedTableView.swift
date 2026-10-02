import AppKit
import NeutrinoCore

/// A CSV file shown as a table. It is for reading: the first line gives the column titles,
/// a click on a title sorts by that column, the field above keeps only the rows that contain
/// what is typed, and a double click on a row goes to it in the text.
final class DelimitedTableView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuItemValidation {
    /// Called with the place in the text of the row that was double-clicked.
    var onOpen: (Int) -> Void = { _ in }
    /// Called with how many rows are shown and how many there are, when either changes.
    var onCount: (Int, Int) -> Void = { _, _ in }

    let table = NSTableView()
    private let filterField = NSSearchField()
    private var titles: [String] = []
    private var rows: [[String]] = []
    private var offsets: [Int] = []
    /// The rows in the order they are shown, as positions in `rows`.
    private var order: [Int] = []
    /// Each row as one string without case or accents, for the filter. Made when the filter is
    /// first used.
    private var searchKeys: [String] = []

    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    private static let columnLimit = 256

    override init(frame: NSRect) {
        super.init(frame: frame)
        table.dataSource = self
        table.delegate = self
        table.style = .plain
        table.rowHeight = 20
        table.usesAlternatingRowBackgroundColors = true
        table.allowsColumnReordering = true
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.target = self
        table.doubleAction = #selector(openRow)

        let menu = NSMenu()
        for (title, action) in [
            ("Copy", #selector(copy(_:))), ("Copy as Markdown", #selector(copyAsMarkdown(_:))),
            ("Copy as JSON", #selector(copyAsJSON(_:))),
        ] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        table.menu = menu

        filterField.placeholderString = "Filter rows"
        filterField.controlSize = .small
        filterField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        filterField.sendsSearchStringImmediately = false
        filterField.target = self
        filterField.action = #selector(filterChanged)
        filterField.delegate = self
        filterField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(filterField)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            filterField.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            filterField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            filterField.widthAnchor.constraint(equalToConstant: 240),
            scroll.topAnchor.constraint(equalTo: filterField.bottomAnchor, constant: 5),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ data: DelimitedTable) {
        let first = data.rows.first ?? []
        rows = Array(data.rows.dropFirst())
        offsets = Array(data.offsets.dropFirst())
        searchKeys = []
        titles = (0..<min(data.columnCount, Self.columnLimit)).map { index in
            index < first.count && !first[index].isEmpty ? first[index] : "Column \(index + 1)"
        }

        table.tableColumns.forEach(table.removeTableColumn)
        let digit = ("0" as NSString).size(withAttributes: [.font: Self.font]).width
        for index in titles.indices {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
            column.title = titles[index]
            column.sortDescriptorPrototype = NSSortDescriptor(key: String(index), ascending: true)
            // Wide enough for the title and the first rows, within reason.
            var longest = column.title.count
            for row in rows.prefix(200) where index < row.count { longest = max(longest, row[index].count) }
            column.width = min(max(CGFloat(longest) * digit + 16, 50), 360)
            column.minWidth = 30
            table.addTableColumn(column)
        }
        table.sortDescriptors = []
        arrange()
    }

    /// Puts the keyboard in the filter field.
    func focusFilter() {
        window?.makeFirstResponder(filterField)
    }

    @objc private func filterChanged() {
        arrange()
    }

    /// Escape in the filter field clears it and goes back to the table.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        filterField.stringValue = ""
        arrange()
        window?.makeFirstResponder(table)
        return true
    }

    /// Works out which rows are shown, and in which order, from the filter and the sorted column.
    private func arrange() {
        let filter = Array(Self.folded(filterField.stringValue).utf8)
        var shown = Array(rows.indices)
        if !filter.isEmpty {
            if searchKeys.count != rows.count {
                searchKeys = rows.map { Self.folded($0.joined(separator: "\u{1}")) }
            }
            shown = shown.filter { Self.contains(filter, in: searchKeys[$0]) }
        }
        if let descriptor = table.sortDescriptors.first, let index = descriptor.key.flatMap(Int.init) {
            // Read once per row rather than at every comparison.
            let keys: [(text: String, number: Double?)] = rows.map { row in
                let text = index < row.count ? row[index] : ""
                return (text, Double(text))
            }
            shown.sort { a, b in
                let ascending: Bool
                if let p = keys[a].number, let q = keys[b].number {
                    ascending = p != q ? p < q : a < b
                } else {
                    let result = keys[a].text.localizedStandardCompare(keys[b].text)
                    ascending = result != .orderedSame ? result == .orderedAscending : a < b
                }
                return descriptor.ascending ? ascending : !ascending
            }
        }
        order = shown
        table.reloadData()
        onCount(order.count, rows.count)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        order.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let index = Int(tableColumn.identifier.rawValue) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField
            ?? {
                let cell = NSTextField(labelWithString: "")
                cell.identifier = identifier
                cell.font = Self.font
                cell.lineBreakMode = .byTruncatingTail
                return cell
            }()
        let fields = rows[order[row]]
        cell.stringValue = index < fields.count ? fields[index] : ""
        return cell
    }

    /// Sorts by the clicked column: as numbers when both values are numbers, as text otherwise.
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        arrange()
    }

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Whether the bytes occur in the text. Comparing bytes is many times quicker than a
    /// string search, which matters with 200,000 rows.
    private static func contains(_ needle: [UInt8], in text: String) -> Bool {
        let found = text.utf8.withContiguousStorageIfAvailable { bytes -> Bool in
            guard bytes.count >= needle.count else { return false }
            let first = needle[0]
            for start in 0...(bytes.count - needle.count) where bytes[start] == first {
                var matched = 1
                while matched < needle.count, bytes[start + matched] == needle[matched] { matched += 1 }
                if matched == needle.count { return true }
            }
            return false
        }
        return found ?? text.contains(String(decoding: needle, as: UTF8.self))
    }

    // MARK: Copying

    /// The selected rows, or every row shown when none is selected, without the columns past
    /// the limit.
    private var chosenRows: [[String]] {
        let chosen = table.selectedRowIndexes.isEmpty ? Array(order.indices) : Array(table.selectedRowIndexes)
        return chosen.filter(order.indices.contains).map { Array(rows[order[$0]].prefix(titles.count)) }
    }

    private func put(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Edit > Copy reaches this through the table, which is inside this view.
    @objc func copy(_ sender: Any?) {
        put(DelimitedTable.tabSeparated([titles] + chosenRows))
    }

    @objc func copyAsMarkdown(_ sender: Any?) {
        put(DelimitedTable.markdown(titles: titles, rows: chosenRows))
    }

    @objc func copyAsJSON(_ sender: Any?) {
        put(DelimitedTable.json(titles: titles, rows: chosenRows))
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        !order.isEmpty
    }

    @objc private func openRow() {
        guard order.indices.contains(table.clickedRow) else { return }
        onOpen(offsets[order[table.clickedRow]])
    }
}
