import AppKit
import NeutrinoCore

/// Commands that work on the whole editor window: the shell filter and the symbol menu.
extension EditorWindowController {
    /// Longest a shell command may run before it is stopped.
    private static let filterTimeout = 30.0

    // MARK: Filter through a shell command

    /// Sends the selection, or the whole text, through a shell command and replaces it with
    /// what the command prints.
    @objc func filterThroughCommand(_ sender: Any?) {
        guard let window, textView.isEditable else { return NSSound.beep() }
        let selection = textView.selectedRange()
        let alert = NSAlert()
        alert.messageText = "Filter Through Command"
        alert.informativeText = (selection.length > 0 ? "The selection" : "The whole text")
            + " is sent to the command and replaced with its output."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 22))
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.placeholderString = "sort -u"
        field.stringValue = UserDefaults.standard.string(forKey: Prefs.filterCommand) ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            let command = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard let self, response == .alertFirstButtonReturn, !command.isEmpty else { return }
            UserDefaults.standard.set(command, forKey: Prefs.filterCommand)
            self.run(command, on: selection.length > 0 ? selection : NSRange(location: 0, length: self.text.length))
        }
    }

    private func run(_ command: String, on range: NSRange) {
        let input = text.substring(with: range)
        let process = Process()
        // A login shell, so the command sees the same PATH as in Terminal.
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        process.arguments = ["-l", "-c", command]
        process.currentDirectoryURL = doc?.fileURL?.deletingLastPathComponent()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        // Nothing may change while the command runs, or its output would land in the wrong place.
        setEditable(false)
        statusBar.setPosition("Running \(command)…")
        let finish = { [weak self] in
            guard let self else { return }
            self.setEditable(true)
            self.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification))
        }

        do {
            try process.run()
        } catch {
            finish()
            return report("The command couldn't be started", error.localizedDescription)
        }
        let queue = DispatchQueue.global(qos: .userInitiated)
        let group = DispatchGroup()
        var output = Data()
        var errors = Data()
        // Each pipe gets its own thread, so a command that prints a lot can't block on a full pipe.
        queue.async(group: group) { output = stdout.fileHandleForReading.readDataToEndOfFile() }
        queue.async(group: group) { errors = stderr.fileHandleForReading.readDataToEndOfFile() }
        queue.async {
            // Fails harmlessly when the command exits without reading everything, as `head` does.
            try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        var timedOut = false
        let timer = DispatchWorkItem {
            timedOut = true
            process.terminate()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.filterTimeout, execute: timer)
        queue.async {
            process.waitUntilExit()
            group.wait()
            DispatchQueue.main.async { [weak self] in
                timer.cancel()
                finish()
                guard let self else { return }
                let message = String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if timedOut {
                    return self.report("The command was stopped", "It ran for more than \(Int(Self.filterTimeout)) seconds.")
                }
                guard process.terminationStatus == 0 else {
                    return self.report("The command failed with status \(process.terminationStatus)", String(message.prefix(1000)))
                }
                guard NSMaxRange(range) <= self.text.length, self.text.substring(with: range) == input else {
                    return self.report("The text changed while the command ran", "Nothing was replaced.")
                }
                let result = TextCodec.normalized(String(decoding: output, as: UTF8.self))
                self.textView.replace(range, with: result)
                self.textView.setSelectedRange(NSRange(location: range.location, length: (result as NSString).length))
            }
        }
    }

    private func report(_ title: String, _ detail: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.beginSheetModal(for: window)
    }

    // MARK: Path or link at the caret

    private static let pathBreaks: NSCharacterSet = {
        var set = CharacterSet.whitespacesAndNewlines
        set.insert(charactersIn: "\"'`<>()[]{}|")
        return set as NSCharacterSet
    }()

    /// The selection, or the run of text around the caret that could be a path or a link.
    private func pathAtCaret() -> String {
        let selection = textView.selectedRange()
        if selection.length > 0 { return text.substring(with: selection) }
        var start = selection.location
        var end = selection.location
        while start > 0, !Self.pathBreaks.characterIsMember(text.character(at: start - 1)), end - start < 2000 { start -= 1 }
        while end < text.length, !Self.pathBreaks.characterIsMember(text.character(at: end)), end - start < 2000 { end += 1 }
        return text.substring(with: NSRange(location: start, length: end - start))
    }

    /// Opens the link at the caret in the browser, or the file there in a tab. A path may be
    /// relative to this document's folder and may end in `:line` or `:line:column`.
    @objc func openPathAtCaret(_ sender: Any?) {
        var target = pathAtCaret().trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = target.last, ".,;".contains(last) { target.removeLast() }
        guard !target.isEmpty else { return NSSound.beep() }
        if target.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*://", options: .regularExpression) != nil {
            guard let url = URL(string: target), ["http", "https", "mailto", "file"].contains(url.scheme?.lowercased() ?? "")
            else { return NSSound.beep() }
            NSWorkspace.shared.open(url)
            return
        }
        var position: [Int] = []
        if let suffix = target.range(of: "(:\\d+){1,2}:?$", options: .regularExpression) {
            position = target[suffix].split(separator: ":").compactMap { Int($0) }
            target.removeSubrange(suffix)
        }
        let expanded = (target as NSString).expandingTildeInPath
        let base = doc?.fileURL?.deletingLastPathComponent()
        let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : base?.appendingPathComponent(expanded)
        var isFolder: ObjCBool = false
        guard let url, FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { return NSSound.beep() }
        if isFolder.boolValue {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        NSDocumentController.shared.openDocument(withContentsOf: url.standardizedFileURL, display: true) { document, _, _ in
            guard let line = position.first else { return }
            (document as? Document)?.editor?.go(toLine: line, column: position.count > 1 ? position[1] : 1)
        }
    }

    // MARK: Symbols

    /// Functions, classes and headings in the document, found with the patterns of its syntax.
    /// Matches inside comments and strings are left out.
    func symbols() -> [Symbol] {
        guard let doc, let syntax = doc.syntax else { return [] }
        // A copy, made once: each pattern would otherwise copy the text for itself.
        return syntax.symbols(in: doc.snapshotText()).filter { symbol in
            let found = Self.firstIndex(in: tokens, endingAfter: symbol.range.location) { $0.range }
            guard found < tokens.count, tokens[found].range.location <= symbol.range.location else { return true }
            switch tokens[found].scope {
            case .string: return false
            // A comment such as "// MARK: Drawing" is a symbol even though it is a comment.
            case .comment: return text.substring(with: tokens[found].range).contains("MARK:")
            default: return true
            }
        }
    }

    @objc func showSymbols(_ sender: Any?) {
        statusBar.openSymbols()
    }

    func reveal(_ symbol: Symbol) {
        guard NSMaxRange(symbol.range) <= text.length else { return }
        textView.setSelectedRange(NSRange(location: symbol.range.location, length: 0))
        textView.scrollRangeToVisible(text.lineRange(for: symbol.range))
        textView.showFindIndicator(for: symbol.range)
        window?.makeFirstResponder(textView)
    }
}
