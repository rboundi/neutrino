import AppKit
import NeutrinoCore

/// A CSV file shown as a table. It is for reading: the first line gives the column titles,
/// a click on a title sorts by that column, and a double click on a row goes to it in the text.
final class DelimitedTableView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    /// Called with the place in the text of the row that was double-clicked.
    var onOpen: (Int) -> Void = { _ in }

    let table = NSTableView()
    private var rows: [[String]] = []
    private var offsets: [Int] = []
    /// The rows in the order they are shown, as positions in `rows`.
    private var order: [Int] = []

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
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.target = self
        table.doubleAction = #selector(openRow)

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
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ data: DelimitedTable) {
        let titles = data.rows.first ?? []
        rows = Array(data.rows.dropFirst())
        offsets = Array(data.offsets.dropFirst())
        order = Array(rows.indices)

        table.tableColumns.forEach(table.removeTableColumn)
        let digit = ("0" as NSString).size(withAttributes: [.font: Self.font]).width
        for index in 0..<min(data.columnCount, Self.columnLimit) {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
            column.title = index < titles.count && !titles[index].isEmpty ? titles[index] : "Column \(index + 1)"
            column.sortDescriptorPrototype = NSSortDescriptor(key: String(index), ascending: true)
            // Wide enough for the title and the first rows, within reason.
            var longest = column.title.count
            for row in rows.prefix(200) where index < row.count { longest = max(longest, row[index].count) }
            column.width = min(max(CGFloat(longest) * digit + 16, 50), 360)
            column.minWidth = 30
            table.addTableColumn(column)
        }
        table.sortDescriptors = []
        table.reloadData()
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
        guard let descriptor = tableView.sortDescriptors.first, let index = descriptor.key.flatMap(Int.init) else {
            order = Array(rows.indices)
            return tableView.reloadData()
        }
        func value(_ row: Int) -> String { index < rows[row].count ? rows[row][index] : "" }
        order = rows.indices.sorted { a, b in
            let (x, y) = (value(a), value(b))
            let ascending: Bool
            if let p = Double(x), let q = Double(y) {
                ascending = p != q ? p < q : a < b
            } else {
                let result = x.localizedStandardCompare(y)
                ascending = result != .orderedSame ? result == .orderedAscending : a < b
            }
            return descriptor.ascending ? ascending : !ascending
        }
        tableView.reloadData()
    }

    @objc private func openRow() {
        guard order.indices.contains(table.clickedRow) else { return }
        onOpen(offsets[order[table.clickedRow]])
    }
}
