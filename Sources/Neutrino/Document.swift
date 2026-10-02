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
    /// How the text itself is indented, worked out when it is read. Nil if it can't be told.
    private var detectedIndentation: EditorConfig?
    /// Indentation picked for this document from the status bar; it wins over everything else.
    private var chosenIndentation = EditorConfig()
    private(set) var lineIndex = LineIndex()
    private(set) var encoding: String.Encoding = .utf8
    private(set) var hasBOM = false
    private(set) var lineEnding: LineEnding = .lf
    private(set) var syntax: CompiledSyntax?
    /// Set once the syntax is picked by hand, so saving under a new name doesn't change it.
    private var syntaxIsManual = false
    /// The bytes of a file that isn't text. It is shown as hex and can't be edited.
    private(set) var binaryData: Data?
    /// Counts the times the file was read, so the window can tell new bytes from the ones it shows.
    private(set) var readCount = 0
    /// The lines of the text as it was opened or last saved by hand, as one number each, for
    /// marking the lines changed since. Nil for a new document and for a very long text.
    private(set) var baseline: [Int]?
    /// Longest text, in UTF-16 units, whose changed lines are marked.
    static let changeMarkLimit = 2_000_000
    /// Whether the last autosave failed, so the error is shown once and not on every attempt.
    private var autosaveFailed = false

    /// What a save writes, copied on the main thread so encoding and writing can happen off it.
    private struct Snapshot {
        var text: String
        var encoding: String.Encoding
        var hasBOM: Bool
        var lineEnding: LineEnding
        var binary: Data?
    }
    private var snapshot: Snapshot?
    private let snapshotLock = NSLock()

    var editor: EditorWindowController? {
        windowControllers.first as? EditorWindowController
    }

    /// The editor settings for this document: the global ones, then the indentation the file
    /// already uses, then what `.editorconfig` says.
    var style: EditorStyle {
        var style = EditorStyle.current
        if let detectedIndentation, UserDefaults.standard.bool(forKey: Prefs.detectIndentation) {
            style = style.applying(detectedIndentation)
        }
        return style.applying(editorConfig).applying(chosenIndentation)
    }

    /// Sets how this document is indented, until it is closed.
    func setIndentation(spaces: Bool? = nil, width: Int? = nil) {
        if let spaces { chosenIndentation.indentWithSpaces = spaces }
        if let width { chosenIndentation.indentWidth = width }
        NotificationCenter.default.post(name: Self.formatDidChange, object: self)
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
            editor?.updateTitleButton()
            let config = fileURL.map { EditorConfig.load(for: $0) } ?? EditorConfig()
            editorConfig = config
            // Also when the settings are the same: a new name can make it a Markdown file.
            NotificationCenter.default.post(name: Self.formatDidChange, object: self)
        }
    }

    // MARK: Reading

    override func read(from url: URL, ofType typeName: String) throws {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        // Asked when the file is first opened, not when it is reloaded after changing on disk.
        if size >= Self.largeFileLimit, windowControllers.isEmpty {
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
        readCount += 1
        // Asked for as text, with Reopen with Encoding, a binary file is shown as text.
        if encoding == nil, TextCodec.looksBinary(data) {
            binaryData = data
            baseline = nil
            setText("")
            NotificationCenter.default.post(name: Self.formatDidChange, object: self)
            return
        }
        binaryData = nil
        guard let decoded = TextCodec.decode(data, as: encoding) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadInapplicableStringEncodingError)
        }
        self.encoding = decoded.encoding
        hasBOM = decoded.hasBOM
        lineEnding = decoded.lineEnding
        detectedIndentation = Indentation.detect(in: decoded.text as NSString)
        setText(decoded.text)
        setBaseline(textStorage.length <= Self.changeMarkLimit ? LineHashes.make(textStorage.mutableString) : nil)
        detectSyntax()
        NotificationCenter.default.post(name: Self.formatDidChange, object: self)
    }

    private func setBaseline(_ new: [Int]?) {
        baseline = new
        editor?.baselineChanged()
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
        // The text view adds typed characters to the undo step before them for as long as typing
        // goes on. A document only learns that it has changed from a new undo step, so without
        // this, typing that carries on after a save would not count as a change and would
        // never be saved.
        editor?.breakUndoCoalescing()
        // Only when the user saves: tidying during an automatic save would move text under the caret.
        if [.saveOperation, .saveAsOperation, .saveToOperation].contains(saveOperation) {
            editor?.tidyBeforeSaving()
        }
        setSnapshot(Snapshot(
            text: textStorage.mutableString.copy() as! String, encoding: encoding, hasBOM: hasBOM,
            lineEnding: lineEnding, binary: binaryData))
        // A save by hand is the new starting point for the changed-line marks; an automatic
        // one isn't, or the marks would go after every pause in typing.
        let byHand = [.saveOperation, .saveAsOperation].contains(saveOperation)
        var saved: [Int]?
        if byHand, binaryData == nil, textStorage.length <= Self.changeMarkLimit {
            saved = LineHashes.make(textStorage.mutableString)
        }
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            self?.setSnapshot(nil)
            if error == nil, byHand { self?.setBaseline(saved) }
            // The file now holds this text, whatever the notice was about.
            if error == nil, saveOperation != .autosaveElsewhereOperation, saveOperation != .saveToOperation {
                self?.editor?.hideConflict()
            }
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
        // A binary file is written back as it was read.
        if let binary = saved.binary { return binary }
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
        // Not over a file that another app has changed: that waits for the answer to the notice.
        guard hasUnautosavedChanges, editor?.hasConflict != true else { return }
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
        editor?.savePosition()
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

    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        super.updateChangeCount(change)
        // Once the title bar has caught up, which is when it would show "— Edited".
        if fileURL == nil { DispatchQueue.main.async { [weak self] in self?.editor?.updateTitleButton() } }
    }

    private func formatChanged() {
        updateChangeCount(.changeDone)
        NotificationCenter.default.post(name: Self.formatDidChange, object: self)
    }

    // MARK: Changes on disk

    override func revert(toContentsOf url: URL, ofType typeName: String) throws {
        try super.revert(toContentsOf: url, ofType: typeName)
        editor?.hideConflict()
        // The undo steps describe the old text; applying them to the new text would corrupt it.
        undoManager?.removeAllActions()
    }

    override func presentedItemDidChange() {
        super.presentedItemDidChange()
        DispatchQueue.main.async { self.reloadIfChangedOnDisk() }
    }

    /// The file's modification date, when it is newer than the one this document was read or
    /// saved with: another app has written it since.
    private var newerDateOnDisk: Date? {
        guard let url = fileURL,
            let onDisk = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
            let known = fileModificationDate, onDisk > known
        else { return nil }
        return onDisk
    }

    /// Reads the file again and drops the unsaved changes; from the conflict notice.
    func reloadFromDisk() {
        // Not while a save is under way: it would finish after the reload and call the file saved.
        guard let url = fileURL, let type = fileType, !isSaving else { return NSSound.beep() }
        do {
            try revert(toContentsOf: url, ofType: type)
        } catch {
            presentError(error)
        }
    }

    /// Keeps the text here over what another app wrote: the next save replaces the file
    /// without asking.
    func keepOverDisk() {
        if let date = newerDateOnDisk { fileModificationDate = date }
        scheduleAutosave()
    }

    /// Whether this document is writing its file right now.
    private var isSaving: Bool {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return snapshot != nil
    }

    /// Picks up edits made by another app, as long as there is nothing unsaved here to lose.
    /// When there is, it says so and leaves the choice to the user.
    private func reloadIfChangedOnDisk() {
        guard let url = fileURL, let type = fileType, newerDateOnDisk != nil else { return }
        guard !isDocumentEdited else {
            // Not while this document is itself writing the file.
            if !isSaving { editor?.showConflict() }
            return
        }
        // With the caret on the last line, stay at the end as the file grows, like `tail -f`.
        let caret = editor?.textView.selectedRange().location ?? 0
        let follows = textStorage.length > 0 && lineIndex.line(at: caret) == lineIndex.count - 1
        try? revert(toContentsOf: url, ofType: type)
        if follows { editor?.followEnd() }
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
        compare(
            old: saved, named: "\(name) (saved)", new: textStorage.string, named: "\(name) (now)",
            title: "Changes in \(name)", same: "The text is the same as the saved file.")
    }

    /// The folder of the Git repository the file is in, found by its `.git`.
    private var gitRoot: URL? {
        guard var folder = fileURL?.deletingLastPathComponent().standardizedFileURL else { return nil }
        while folder.path != "/" {
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) { return folder }
            folder = folder.deletingLastPathComponent().standardizedFileURL
        }
        return nil
    }

    /// Opens a new document with the differences between the last commit and the text here.
    @objc func compareWithGitHead(_ sender: Any?) {
        guard let url = fileURL, gitRoot != nil else { return NSSound.beep() }
        let name = url.lastPathComponent
        let current = textStorage.string
        let encoding = self.encoding
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.currentDirectoryURL = url.deletingLastPathComponent()
            process.arguments = ["show", "HEAD:./\(name)"]
            let output = Pipe()
            let errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            var committed: String?
            // What Git says when it can't: a file that was never committed, no commits yet,
            // a folder it doesn't trust.
            var reason = "Git couldn't be started."
            if (try? process.run()) != nil {
                // Git writes either the file or a short message, so reading one then the other can't block.
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let message = errors.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus == 0 { committed = TextCodec.decode(data, as: encoding)?.text ?? TextCodec.decode(data)?.text }
                reason = String(decoding: message.prefix(600), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let diff = committed.flatMap { UnifiedDiff.make(old: $0, new: current, oldName: "\(name) (HEAD)", newName: "\(name) (now)") }
            DispatchQueue.main.async {
                guard committed != nil else {
                    let alert = NSAlert()
                    alert.messageText = "Git has no committed “\(name)” to compare with"
                    alert.informativeText = reason
                    alert.runModal()
                    return
                }
                self?.showComparison(diff, title: "Changes in \(name) since HEAD", same: "The text is the same as in the last commit.")
            }
        }
    }

    /// Opens a new document with the differences between this document and another open one.
    /// The menu item carries the other document.
    @objc func compareWithTab(_ sender: NSMenuItem) {
        guard let other = sender.representedObject as? Document else { return }
        let name = displayName ?? "Untitled"
        let otherName = other.displayName ?? "Untitled"
        compare(
            old: textStorage.string, named: name, new: other.textStorage.string, named: otherName,
            title: "\(name) and \(otherName)", same: "The two documents have the same text.")
    }

    /// Opens a new document with the differences between this document and the clipboard.
    @objc func compareWithClipboard(_ sender: Any?) {
        guard let copied = NSPasteboard.general.string(forType: .string) else { return NSSound.beep() }
        let name = displayName ?? "Untitled"
        compare(
            old: textStorage.string, named: name, new: TextCodec.normalized(copied), named: "Clipboard",
            title: "\(name) and the clipboard", same: "The clipboard has the same text as the document.")
    }

    // MARK: The file

    @objc func revealInFinder(_ sender: Any?) {
        if let fileURL { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
    }

    @objc func copyPath(_ sender: Any?) {
        guard let fileURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fileURL.path, forType: .string)
    }

    /// Opens a Terminal window in the file's folder.
    @objc func openTerminalHere(_ sender: Any?) {
        guard let folder = fileURL?.deletingLastPathComponent(),
            let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
        else { return NSSound.beep() }
        NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Whether the text is short enough to compare without a long wait.
    var isComparable: Bool { textStorage.length < 20 << 20 }

    private func compare(
        old: String, named oldName: String, new: String, named newName: String, title: String, same: String
    ) {
        // Off the main thread: comparing two very different long files takes a while.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let diff = UnifiedDiff.make(old: old, new: new, oldName: oldName, newName: newName)
            DispatchQueue.main.async { [weak self] in self?.showComparison(diff, title: title, same: same) }
        }
    }

    private func showComparison(_ diff: String?, title: String, same: String) {
        guard let diff else {
            let alert = NSAlert()
            alert.messageText = "No differences"
            alert.informativeText = same
            alert.runModal()
            return
        }
        guard let controller = NSDocumentController.shared as? DocumentController,
            let document = try? controller.makeUntitledDocument(ofType: Self.typeName) as? Document
        else { return }
        document.setText(diff)
        document.displayName = title
        document.setSyntax(id: "diff")
        controller.addDocument(document)
        document.makeWindowControllers()
        document.showWindows()
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(compareWithSaved(_:)): return fileURL != nil && isComparable
        case #selector(compareWithGitHead(_:)): return isComparable && gitRoot != nil
        case #selector(compareWithClipboard(_:)): return isComparable
        case #selector(revealInFinder(_:)), #selector(copyPath(_:)), #selector(openTerminalHere(_:)):
            return fileURL != nil
        case #selector(previewInMDReader(_:)): return isMarkdown && fileURL != nil
        default: return super.validateUserInterfaceItem(item)
        }
    }

    // MARK: MDReader

    /// By its syntax or, when that isn't installed, by the file's extension.
    var isMarkdown: Bool {
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
        // Syntax colours too, in their light-background form. Not for a very long text, where
        // colouring the copy would take a while.
        if let storage = view.textStorage, storage.length <= 2_000_000, let tokens = editor?.printableTokens {
            var colours: [Scope: NSColor] = [:]
            storage.beginEditing()
            for token in tokens where NSMaxRange(token.range) <= storage.length {
                let colour = colours[token.scope] ?? Theme.printColor(for: token.scope)
                colours[token.scope] = colour
                storage.addAttribute(.foregroundColor, value: colour, range: token.range)
            }
            storage.endEditing()
        }
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

    /// Unsaved text kept across a quit when files aren't saved automatically.
    private struct Draft: Codable {
        /// The file the text belongs to; nil for a document that was never saved.
        var path: String?
        var text: String
    }

    private static let draftsFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Neutrino/unsaved.json")

    /// Quitting doesn't ask about unsaved documents; only closing a tab does. The unsaved text
    /// is written aside here and put back by `restoreDrafts` at the next launch.
    ///
    /// With files saved automatically, macOS already keeps everything across a quit, so this
    /// only steps in when that setting is off. With "Keep windows and unsaved text when
    /// quitting" off, or if the text can't be written, the usual questions are asked.
    override func reviewUnsavedDocuments(
        withAlertTitle title: String?, cancellable: Bool, delegate: Any?, didReviewAllSelector: Selector?,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        let review = {
            super.reviewUnsavedDocuments(
                withAlertTitle: title, cancellable: cancellable, delegate: delegate,
                didReviewAllSelector: didReviewAllSelector, contextInfo: contextInfo)
        }
        guard UserDefaults.standard.bool(forKey: Prefs.keepWindows), !Document.autosavesInPlace,
            let delegate = delegate as AnyObject?, let selector = didReviewAllSelector
        else { return review() }

        // A document that was never saved counts whenever it has text: once macOS has copied it
        // aside it no longer reports itself as edited.
        let unsaved = documents.compactMap { $0 as? Document }.filter {
            $0.isDocumentEdited || ($0.fileURL == nil && $0.textStorage.length > 0)
        }
        let drafts = unsaved.map {
            Draft(path: $0.fileURL?.path, text: $0.textStorage.string)
        }
        if drafts.isEmpty {
            // Nothing is unsaved, so there is nothing to keep and nothing to ask about.
            try? FileManager.default.removeItem(at: Self.draftsFile)
        } else {
            do {
                try FileManager.default.createDirectory(
                    at: Self.draftsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(drafts).write(to: Self.draftsFile, options: .atomic)
            } catch {
                return review()
            }
        }
        // The callback is documentController:didReviewAll:contextInfo:, which Swift can only
        // reach through its implementation pointer.
        typealias Callback = @convention(c) (AnyObject, Selector, NSDocumentController, Bool, UnsafeMutableRawPointer?) -> Void
        let callback = unsafeBitCast(delegate.method(for: selector), to: Callback.self)
        callback(delegate, selector, self, true, contextInfo)
    }

    /// Puts back the unsaved text written at the last quit, as unsaved changes.
    func restoreDrafts() {
        guard let data = try? Data(contentsOf: Self.draftsFile),
            let drafts = try? JSONDecoder().decode([Draft].self, from: data)
        else { return }
        let pending = DispatchGroup()
        for draft in drafts {
            if let path = draft.path {
                guard FileManager.default.fileExists(atPath: path) else {
                    // The file is gone; keep the text as a new document rather than lose it.
                    restore(draft.text, in: nil)
                    continue
                }
                pending.enter()
                openDocument(withContentsOf: URL(fileURLWithPath: path), display: true) { document, _, _ in
                    self.restore(draft.text, in: document as? Document)
                    pending.leave()
                }
            } else {
                restore(draft.text, in: nil)
            }
        }
        // Only once every draft is back in a document; until then the file is the only copy.
        pending.notify(queue: .main) {
            try? FileManager.default.removeItem(at: Self.draftsFile)
        }
    }

    private func restore(_ text: String, in document: Document?) {
        let blank = documents.compactMap { $0 as? Document }.first(where: \.isBlank)
        guard let document = document ?? blank ?? (try? openUntitledDocumentAndDisplay(true)) as? Document,
            let textView = document.editor?.textView
        else { return }
        let whole = NSRange(location: 0, length: document.textStorage.length)
        // A file that can't be written opens locked, and a locked document refuses the text.
        if document.editor?.isLocked == true { document.editor?.toggleLock(nil) }
        if document.textStorage.string != text {
            textView.replace(whole, with: text)
            textView.setSelectedRange(NSRange(location: 0, length: 0))
        }
    }

    /// A new document holding the text on the clipboard.
    @objc func newFromClipboard(_ sender: Any?) {
        guard let copied = NSPasteboard.general.string(forType: .string),
            let document = try? openUntitledDocumentAndDisplay(true) as? Document
        else { return NSSound.beep() }
        document.editor?.textView.replace(NSRange(location: 0, length: 0), with: TextCodec.normalized(copied))
        document.editor?.textView.setSelectedRange(NSRange(location: 0, length: 0))
    }

    /// Opening or closing a document can give two tabs the same name, or end that.
    private func refreshTitles() {
        for case let document as Document in documents {
            document.editor?.synchronizeWindowTitleWithDocumentName()
        }
    }

    override func addDocument(_ document: NSDocument) {
        super.addDocument(document)
        refreshTitles()
    }

    override func removeDocument(_ document: NSDocument) {
        super.removeDocument(document)
        refreshTitles()
    }

    @objc func reopenClosedTab(_ sender: Any?) {
        while let url = closed.popLast() {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            return openDocument(withContentsOf: url, display: true) { _, _, _ in }
        }
        NSSound.beep()
    }

    /// Where `neutrino file:12:3` leaves the line and column for the app to pick up.
    static let positionRequest = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("\(Bundle.main.bundleIdentifier ?? "com.movinapp.neutrino.macos")/goto")

    /// The line and column the `neutrino` command asked for when it opened this file a moment
    /// ago. The request is a file with the path, line and column on three lines; it is used once.
    private static func requestedPosition(for url: URL) -> (line: Int, column: Int)? {
        let request = positionRequest
        guard let written = try? request.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
            let text = try? String(contentsOf: request, encoding: .utf8)
        else { return nil }
        let fields = text.components(separatedBy: "\n")
        guard fields.count >= 3, URL(fileURLWithPath: fields[0]).resolvingSymlinksInPath() == url.resolvingSymlinksInPath()
        else { return nil }
        try? FileManager.default.removeItem(at: request)
        guard Date().timeIntervalSince(written) < 30, let line = Int(fields[1]) else { return nil }
        return (line, Int(fields[2]) ?? 1)
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
                // Checked again here: text may have gone into one of them while the file opened.
                blanks.filter(\.isBlank).forEach { $0.close() }
            }
            if let position = Self.requestedPosition(for: url) {
                (document as? Document)?.editor?.go(toLine: position.line, column: position.column)
            }
            completionHandler(document, alreadyOpen, error)
        }
    }
}
