import AppKit

/// One view of a document: the text with its line numbers beside it. A window has one, or two
/// when it is split; both show the same text storage, so an edit in one appears in the other.
final class EditorPane {
    let textView: EditorTextView
    let layoutManager = EditorLayoutManager()
    let scrollView = NSScrollView()
    let gutter = GutterView()
    /// The gutter and the scroll view side by side.
    let view = NSView()
    /// The characters whose colours are applied. Colours belong to the layout manager, so each
    /// pane keeps track of its own.
    var decorated = NSRange(location: 0, length: 0)

    private let gutterWidth: NSLayoutConstraint

    init(storage: NSTextStorage) {
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.allowsNonContiguousLayout = true
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        textView = EditorTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 500), textContainer: container)
        gutterWidth = gutter.widthAnchor.constraint(equalToConstant: 40)

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
        textView.textContainerInset = NSSize(width: 2, height: 10)
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.postsFrameChangedNotifications = true

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.contentView.postsBoundsChangedNotifications = true
        gutter.textView = textView

        for part in [gutter, scrollView] as [NSView] {
            part.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(part)
        }
        NSLayoutConstraint.activate([
            gutterWidth,
            gutter.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            gutter.topAnchor.constraint(equalTo: view.topAnchor),
            gutter.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: gutter.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        applyTheme()
    }

    /// Takes the colours of the theme in use.
    func applyTheme() {
        textView.backgroundColor = Theme.background
        textView.insertionPointColor = Theme.text
        textView.selectedTextAttributes = [.backgroundColor: Theme.selection]
        scrollView.backgroundColor = Theme.background
        textView.needsDisplay = true
        gutter.needsDisplay = true
    }

    func applyWrap(_ wrap: Bool) {
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

    /// Makes room for the largest line number, or none when line numbers are off.
    func setLineNumbers(shown: Bool, lineCount: Int) {
        gutter.isHidden = !shown
        let width = shown ? gutter.width(forLineCount: lineCount) : 0
        if gutterWidth.constant != width { gutterWidth.constant = width }
    }

    /// The characters on screen, and those within a screen above and below.
    func visibleCharacters(padded: Bool) -> NSRange {
        guard let container = textView.textContainer else { return NSRange(location: 0, length: 0) }
        var rect = textView.visibleRect
        if padded { rect = rect.insetBy(dx: 0, dy: -rect.height) }
        let glyphs = layoutManager.glyphRange(forBoundingRect: rect, in: container)
        return layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    }
}
