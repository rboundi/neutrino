import AppKit
import NeutrinoCore

/// An open file: its text, how it is encoded on disk, and which syntax colours it.
final class Document: NSDocument, NSTextStorageDelegate {
    static let syntaxDidChange = Notification.Name("DocumentSyntaxDidChange")
    static let formatDidChange = Notification.Name("DocumentFormatDidChange")
    static let typeName = "public.data"

    let textStorage = NSTextStorage()
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
        didSet { if oldValue != fileURL { detectSyntax() } }
    }

    // MARK: Reading

    override func read(from url: URL, ofType typeName: String) throws {
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
    private func setText(_ text: String) {
        let selection = editor?.textView.selectedRange()
        undoManager?.disableUndoRegistration()
        textStorage.setAttributedString(NSAttributedString(string: text, attributes: EditorStyle.current.textAttributes))
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
    override var defaultType: String? { Document.typeName }

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
