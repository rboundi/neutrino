import AppKit

/// A file that isn't text, shown as rows of sixteen bytes: the offset, the bytes in hex and
/// the printable ones as characters. Only the rows on screen are ever made.
final class HexView: NSView {
    /// Most bytes shown. Every row is a place to scroll to, and a view can only be so tall.
    static let limit = 16 << 20

    private let rows = HexRows()
    private let scroll = NSScrollView()

    var data: Data {
        get { rows.data }
        set {
            rows.data = newValue.prefix(Self.limit)
            rows.resize()
            rows.scroll(.zero)
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.documentView = rows
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError() }

    func applyTheme() {
        scroll.backgroundColor = Theme.background
        rows.needsDisplay = true
    }

    /// The same size as the text would have.
    func setFontSize(_ size: Double) {
        rows.font = .monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)
    }
}

private final class HexRows: NSView {
    var data = Data()
    var font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) {
        didSet { resize() }
    }

    private static let perRow = 16
    private static let digits = Array("0123456789abcdef".utf16)

    override var isFlipped: Bool { true }

    private var rowHeight: CGFloat { (font.ascender - font.descender + font.leading).rounded(.up) + 3 }
    private var rowCount: Int { (data.count + Self.perRow - 1) / Self.perRow }

    func resize() {
        let character = ("0" as NSString).size(withAttributes: [.font: font]).width
        // Offset, sixteen bytes with a gap in the middle, and the characters.
        let columns = CGFloat(10 + 3 * Self.perRow + 2 + Self.perRow)
        setFrameSize(NSSize(width: (character * columns).rounded(.up) + 20, height: CGFloat(rowCount) * rowHeight + 20))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.background.setFill()
        dirtyRect.fill()
        guard !data.isEmpty else { return }
        let height = rowHeight
        let first = max(Int((dirtyRect.minY - 10) / height), 0)
        let last = min(Int((dirtyRect.maxY - 10) / height), rowCount - 1)
        guard first <= last else { return }
        let text: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.text]
        let faint: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.gutterText]
        let offsetWidth = ("00000000  " as NSString).size(withAttributes: text).width
        let base = data.startIndex
        for row in first...last {
            let start = row * Self.perRow
            let bytes = data[(base + start)..<(base + min(start + Self.perRow, data.count))]
            var hex: [unichar] = []
            var characters: [unichar] = []
            hex.reserveCapacity(3 * Self.perRow + 2)
            for (index, byte) in bytes.enumerated() {
                hex.append(Self.digits[Int(byte >> 4)])
                hex.append(Self.digits[Int(byte & 15)])
                hex.append(0x20)
                if index == 7 { hex.append(0x20) }
                characters.append(byte >= 0x20 && byte < 0x7F ? unichar(byte) : 0x2E)
            }
            // A short last row is padded, so the characters stay in their column.
            let width = 3 * Self.perRow + 2
            while hex.count < width { hex.append(0x20) }
            let y = 10 + CGFloat(row) * height
            (String(format: "%08x", start) as NSString).draw(at: NSPoint(x: 10, y: y), withAttributes: faint)
            let line = String(utf16CodeUnits: hex, count: hex.count) + String(utf16CodeUnits: characters, count: characters.count)
            (line as NSString).draw(at: NSPoint(x: 10 + offsetWidth, y: y), withAttributes: text)
        }
    }
}
