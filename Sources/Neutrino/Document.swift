import AppKit
import NeutrinoCore

/// An open file: its text, how it is encoded on disk, and which syntax colours it.
final class Document: NSDocument, NSTextStorageDelegate {
    static let syntaxDidChange = Notification.Name("DocumentSyntaxDidChange")
    static let formatDidChange = Notification.Name("DocumentFormatDidChange")
    static let typeName = "public.data"

    /// Opening a file this large asks first: the whole text is held in memory, several times over.
    static let largeFileLimit = 150 << 20

    let textStorage = NSTextStorage()
    /// What the folder's `.editorconfig` files say about this document.
    private(set) var editorConfig = EditorConfig()
    private(set) var lineIndex = LineIndex()
    private(set) var encoding: String.Encoding = .utf8
    private(set) var hasBOM = false
    private(set) var lineEnding: LineEnding = .lf
    private(set) var syntax: CompiledSyntax?
    /// Set once the syntax is picked by hand, so saving under a new name doesn't change it.
    private var syntaxIsManual = false
    /// Whether the last autosave failed, so the error is shown once and not on every attempt.
    private var autosaveFailed = false

    /// What a save writes, copied on the main thread so encoding and writing can happen off it.
    private struct Snapshot {
        var text: String
        var encoding: String.Encoding
        var hasBOM: Bool
        var lineEnding: LineEnding
    }
    private var snapshot: Snapshot?
    private let snapshotLock = NSLock()

    var editor: EditorWindowController? {
        windowControllers.first as? EditorWindowController
    }

    /// The editor settings for this document: the global ones with `.editorconfig` laid over them.
    var style: EditorStyle {
        EditorStyle.current.applying(editorConfig)
    }

    /// The text as a string that is safe to read on another thread.
    func snapshotText() -> NSString {
        textStorage.mutableString.copy() as! NSString
    }

    /// A new, untouched, empty document. Opening a file replaces it.
    var isBlank: Bool {
        fileURL == nil && !isDocumentEdited && textStorage.length == 0
    }

    override init() {
        super.init()
        textStorage.delegate = self
        NotificationCenter.default.addObserver(
            self, selector: #selector(syntaxesChanged), name: SyntaxStore.didChange, object: nil)
    }

    /// With "Save changes automatically" on, edits are written to the file itself and macOS keeps
    /// versions. With it off, unsaved text is still copied aside so a crash doesn't lose it.
    override class var autosavesInPlace: Bool { UserDefaults.standard.bool(forKey: Prefs.autosave) }
    override class var readableTypes: [String] { [typeName] }
    override class var writableTypes: [String] { [typeName] }
    override class func isNativeType(_ type: String) -> Bool { true }
    override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] { [Self.typeName] }
    override func fileNameExtension(forType typeName: String, saveOperation: NSDocument.SaveOperationType) -> String? { nil }
    override var shouldRunSavePanelWithAccessoryView: Bool { false }

    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        // Any name and extension: the editor doesn't decide what kind of file this is.
        savePanel.allowedContentTypes = []
        savePanel.allowsOtherFileTypes = true
        savePanel.isExtensionHidden = false
        return true
    }

    override func makeWindowControllers() {
        addWindowController(EditorWindowController(document: self))
    }

    override var fileURL: URL? {
        didSet {
            guard oldValue != fileURL else { return }
            detectSyntax()
            let config = fileURL.map { EditorConfig.load(for: $0) } ?? EditorConfig()
            if config != editorConfig {
                editorConfig = config
                NotificationCenter.default.post(name: Self.formatDidChange, object: self)
            }
        }
    }

    // MARK: Reading

    override func read(from url: URL, ofType typeName: String) throws {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size >= Self.largeFileLimit {
            // Text is kept in memory as UTF-16 with layout data on top, so a large file needs
            // several times its size. Say so before the Mac starts swapping.
            let megabytes = { (bytes: Int) in ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory) }
            let alert = NSAlert()
            alert.messageText = "“\(url.lastPathComponent)” is \(megabytes(size))"
            alert.informativeText = "Neutrino keeps the whole file in memory. Opening it will use about \(megabytes(size * 4)), and may be slow."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Open Anyway")
            guard alert.runModal() == .alertSecondButtonReturn else {
                throw CocoaError(.userCancelled)
            }
        }
        try load(Data(contentsOf: url, options: .mappedIfSafe), as: nil)
    }

    private func load(_ data: Data, as encoding: String.Encoding?) throws {
        guard let decoded = TextCodec.decode(data, as: encoding) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadInapplicableStringEncodingError)
        }
        self.encoding = decoded.encoding
        hasBOM = decoded.hasBOM
        lineEnding = decoded.lineEnding
        setText(decoded.text)
        detectSyntax()
        NotificationCenter.default.post(name: Self.formatDidChange, object: self)
    }

    /// Replaces the whole text without leaving an undo step.
    func setText(_ text: String) {
        let selection = editor?.textView.selectedRange()
        undoManager?.disableUndoRegistration()
        textStorage.setAttributedString(NSAttributedString(string: text, attributes: style.textAttributes))
        undoManager?.enableUndoRegistration()
        if let selection, let textView = editor?.textView {
            textView.setSelectedRange(NSRange(location: min(selection.location, textStorage.length), length: 0))
        }
    }

    /// Reads the file again as another encoding, for when the guess was wrong.
    func reopen(as encoding: String.Encoding) {
        guard let url = fileURL else { return }
        do {
            try load(Data(contentsOf: url, options: .mappedIfSafe), as: encoding)
            undoManager?.removeAllActions()
            updateChangeCount(.changeCleared)
        } catch {
            let alert = NSAlert()
            alert.messageText = "The file can't be read as \(TextCodec.name(of: encoding))"
            alert.informativeText = "Its bytes aren't valid in that encoding."
            alert.runModal()
        }
    }

    // MARK: Writing

    override func save(
        to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
        completionHandler: @escaping (Error?) -> Void
    ) {
        // Only when the user saves: tidying during an automatic save would move text under the caret.
        if [.saveOperation, .saveAsOperation, .saveToOperation].contains(saveOperation) {
            editor?.tidyBeforeSaving()
        }
        setSnapshot(Snapshot(
            text: textStorage.mutableString.copy() as! String, encoding: encoding, hasBOM: hasBOM,
            lineEnding: lineEnding))
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            self?.setSnapshot(nil)
            completionHandler(error)
        }
    }

    private func setSnapshot(_ new: Snapshot?) {
        snapshotLock.lock()
        snapshot = new
        snapshotLock.unlock()
    }

    /// Saves run in the background, so a large file doesn't freeze the window while it is written.
    override func canAsynchronouslyWrite(
        to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType
    ) -> Bool { true }

    override func data(ofType typeName: String) throws -> Data {
        snapshotLock.lock()
        let saved = snapshot
        snapshotLock.unlock()
        // The text is already copied, so editing can carry on while it is encoded and written.
        unblockUserInteraction()
        guard let saved else { throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError) }
        let encoding = saved.encoding
        guard let data = TextCodec.encode(
            saved.text, encoding: saved.encoding, hasBOM: saved.hasBOM, lineEnding: saved.lineEnding)
        else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteInapplicableStringEncodingError, userInfo: [
                NSLocalizedDescriptionKey: "The text can't be saved as \(TextCodec.name(of: encoding)).",
                NSLocalizedRecoverySuggestionErrorKey:
                    "It has characters that encoding doesn't include. Choose another encoding in the status bar.",
            ])
        }
        return data
    }

    /// Saves now instead of waiting for a pause in typing. Called when the window or the app
    /// loses focus, so other tools see the current text.
    @objc func autosaveNow() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(autosaveNow), object: nil)
        guard hasUnautosavedChanges else { return }
        autosave(withImplicitCancellability: true) { [weak self] error in
            guard let self else { return }
            guard let error = error as NSError? else { return self.autosaveFailed = false }
            if error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError { return }
            // Say so once, not after every pause in typing.
            guard !self.autosaveFailed, let window = self.editor?.window else { return }
            self.autosaveFailed = true
            self.presentError(error, modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil)
        }
    }

    /// Autosaves once typing has stopped for a moment. Large files wait longer, since writing
    /// them takes long enough to notice.
    private func scheduleAutosave() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(autosaveNow), object: nil)
        let delay = textStorage.length > 5_000_000 ? Prefs.autosaveDelay * 6 : Prefs.autosaveDelay
        perform(#selector(autosaveNow), with: nil, afterDelay: delay)
    }

    override func close() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(autosaveNow), object: nil)
        if let fileURL { (NSDocumentController.shared as? DocumentController)?.noteClosed(fileURL) }
        super.close()
    }

    func setEncoding(_ encoding: String.Encoding) {
        guard encoding != self.encoding else { return }
        self.encoding = encoding
        hasBOM = false
        formatChanged()
    }

    func setLineEnding(_ lineEnding: LineEnding) {
        guard lineEnding != self.lineEnding else { return }
        self.lineEnding = lineEnding
        formatChanged()
    }

    private func formatChanged() {
        updateChangeCount(.changeDone)
        NotificationCenter.default.post(name: Self.formatDidChange, object: self)
    }

    // MARK: Changes on disk

    override func revert(toContentsOf url: URL, ofType typeName: String) throws {
        try super.revert(toContentsOf: url, ofType: typeName)
        // The undo steps describe the old text; applying them to the new text would corrupt it.
        undoManager?.removeAllActions()
    }

    override func presentedItemDidChange() {
        super.presentedItemDidChange()
        DispatchQueue.main.async { self.reloadIfChangedOnDisk() }
    }

    /// Picks up edits made by another app, as long as there is nothing unsaved here to lose.
    private func reloadIfChangedOnDisk() {
        guard let url = fileURL, let type = fileType, !isDocumentEdited,
            let onDisk = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
            let known = fileModificationDate, onDisk > known
        else { return }
        try? revert(toContentsOf: url, ofType: type)
    }

    // MARK: Syntax

    private var firstLine: String {
        let string = textStorage.mutableString
        let line = string.lineRange(for: NSRange(location: 0, length: 0))
        return string.substring(with: NSRange(location: 0, length: min(line.length, 200)))
    }

    private var filename: String {
        fileURL?.lastPathComponent ?? ""
    }

    private func detectSyntax() {
        guard !syntaxIsManual else { return }
        let info = SyntaxStore.shared.installedMatch(filename: filename, firstLine: firstLine)
        apply(info.flatMap { SyntaxStore.shared.syntax(id: $0.id) })
    }

    /// Picks a syntax by hand; nil means plain text.
    func setSyntax(id: String?) {
        syntaxIsManual = true
        apply(id.flatMap { SyntaxStore.shared.syntax(id: $0) })
    }

    /// A published syntax that fits this file but isn't installed.
    var suggestedSyntax: SyntaxInfo? {
        syntax == nil ? SyntaxStore.shared.availableMatch(filename: filename, firstLine: firstLine) : nil
    }

    private func apply(_ new: CompiledSyntax?) {
        guard new !== syntax else { return }
        syntax = new
        NotificationCenter.default.post(name: Self.syntaxDidChange, object: self)
    }

    @objc private func syntaxesChanged() {
        if let id = syntax?.definition.id {
            // Reload in case it was updated; fall back to detection if it was removed.
            if let fresh = SyntaxStore.shared.syntax(id: id) { return apply(fresh) }
            syntaxIsManual = false
        }
        detectSyntax()
    }

    // MARK: Text storage

    func textStorage(
        _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange, changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        lineIndex.edited(newRange: editedRange, delta: delta, in: textStorage.mutableString)
        editor?.textDidEdit(newRange: editedRange, delta: delta)
        scheduleAutosave()
    }

    // MARK: Comparing

    /// Opens a new document with the differences between the file on disk and the text here.
    @objc func compareWithSaved(_ sender: Any?) {
        guard let url = fileURL, let data = try? Data(contentsOf: url, options: .mappedIfSafe),
            let saved = TextCodec.decode(data, as: encoding)?.text
        else { return NSSound.beep() }
        let name = url.lastPathComponent
        guard let diff = UnifiedDiff.make(
            old: saved, new: textStorage.string, oldName: "\(name) (saved)", newName: "\(name) (now)")
        else {
            let alert = NSAlert()
            alert.messageText = "No differences"
            alert.informativeText = "The text is the same as the saved file."
            alert.runModal()
            return
        }
        guard let controller = NSDocumentController.shared as? DocumentController,
            let document = try? controller.makeUntitledDocument(ofType: Self.typeName) as? Document
        else { return }
        document.setText(diff)
        document.displayName = "Changes in \(name)"
        document.setSyntax(id: "diff")
        controller.addDocument(document)
        document.makeWindowControllers()
        document.showWindows()
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(compareWithSaved(_:)): return fileURL != nil && textStorage.length < 20 << 20
        case #selector(previewInMDReader(_:)): return isMarkdown && fileURL != nil
        default: return super.validateUserInterfaceItem(item)
        }
    }

    // MARK: MDReader

    private var isMarkdown: Bool {
        syntax?.definition.id == "markdown"
            || ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn"].contains(fileURL?.pathExtension.lowercased() ?? "")
    }

    /// Opens the file in MDReader, the Markdown reader by the same developer, to see it rendered.
    @objc func previewInMDReader(_ sender: Any?) {
        guard let url = fileURL else { return }
        autosaveNow()
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.movinapp.mdreader.macos") {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        let alert = NSAlert()
        alert.messageText = "MDReader isn't installed"
        alert.informativeText = "MDReader is a free Markdown reader from the same developer. It shows the rendered page and updates as you save."
        alert.addButton(withTitle: "Get MDReader")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn, let page = URL(string: "https://github.com/rboundi/mdreader") {
            NSWorkspace.shared.open(page)
        }
    }

    // MARK: Printing

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        let info = printInfo.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.isVerticallyCentered = false
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        view.textStorage?.setAttributedString(
            NSAttributedString(string: textStorage.string, attributes: [.font: font, .foregroundColor: NSColor.black]))
        return NSPrintOperation(view: view, printInfo: info)
    }
}

/// Opens any file as a `Document`, whatever its type, and keeps one empty window from piling up.
final class DocumentController: NSDocumentController {
    /// Files closed in this session, most recent last, for Reopen Closed Tab.
    private var closed: [URL] = []

    override var defaultType: String? { Document.typeName }

    func noteClosed(_ url: URL) {
        closed.removeAll { $0 == url }
        closed.append(url)
        if closed.count > 20 { closed.removeFirst() }
    }

    @objc func reopenClosedTab(_ sender: Any?) {
        while let url = closed.popLast() {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            return openDocument(withContentsOf: url, display: true) { _, _, _ in }
        }
        NSSound.beep()
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(reopenClosedTab(_:)) { return !closed.isEmpty }
        return super.validateUserInterfaceItem(item)
    }

    override func documentClass(forType typeName: String) -> AnyClass? { Document.self }

    override func typeForContents(of url: URL) throws -> String { Document.typeName }

    override func runModalOpenPanel(_ openPanel: NSOpenPanel, forTypes types: [String]?) -> Int {
        super.runModalOpenPanel(openPanel, forTypes: nil)
    }

    override func openDocument(
        withContentsOf url: URL, display displayDocument: Bool,
        completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void
    ) {
        let blanks = documents.compactMap { $0 as? Document }.filter(\.isBlank)
        super.openDocument(withContentsOf: url, display: displayDocument) { document, alreadyOpen, error in
            if document != nil && !alreadyOpen {
                blanks.forEach { $0.close() }
            }
            completionHandler(document, alreadyOpen, error)
        }
    }
}
