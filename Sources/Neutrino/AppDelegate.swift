import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    static let shared = AppDelegate()

    func applicationWillFinishLaunching(_ notification: Notification) {
        Prefs.register()
        Prefs.keepWindowsByDefault()
        NSApp.appearance = ThemeStore.shared.appearance
        NotificationCenter.default.addObserver(
            self, selector: #selector(defaultsChanged), name: ThemeStore.didChange, object: nil)
        NSApp.mainMenu = MainMenu.build(delegate: self)
        NSWindow.allowsAutomaticWindowTabbing = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(defaultsChanged), name: UserDefaults.didChangeNotification, object: nil)

    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // After the windows macOS restores, so the text goes back into the same tabs.
        DispatchQueue.main.async {
            (NSDocumentController.shared as? DocumentController)?.restoreDrafts()
            self.addOpenRecentIfMissing()
        }
        UpdateChecker.checkIfDue { [weak self] release in self?.offer(release) }
    }

    func applicationDidResignActive(_ notification: Notification) {
        for case let document as Document in NSDocumentController.shared.documents {
            document.autosaveNow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Quitting doesn't close the documents, so their caret positions are remembered here.
        for case let document as Document in NSDocumentController.shared.documents {
            document.editor?.savePosition()
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    @objc private func defaultsChanged() {
        DispatchQueue.main.async {
            let appearance = ThemeStore.shared.appearance
            if NSApp.appearance != appearance { NSApp.appearance = appearance }
        }
    }

    // MARK: Menu commands

    @objc func openQuickly(_ sender: Any?) {
        OpenQuickly.shared.show()
    }

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }

    @objc func toggleSetting(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
    }

    @objc func changeFontSize(_ sender: NSMenuItem) {
        Prefs.changeFontSize(by: Double(sender.tag))
    }

    /// ⌘1 to ⌘8 show that tab of the front window; ⌘9 shows the last one.
    @objc func showTab(_ sender: NSMenuItem) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow, let tabs = window.tabGroup?.windows, !tabs.isEmpty
        else { return }
        let index = sender.tag == 9 ? tabs.count - 1 : sender.tag - 1
        guard tabs.indices.contains(index) else { return NSSound.beep() }
        window.tabGroup?.selectedWindow = tabs[index]
    }

    @objc func openRepository(_ sender: Any?) {
        if let url = URL(string: "https://github.com/\(UpdateChecker.repo)") { NSWorkspace.shared.open(url) }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleSetting(_:)), let key = menuItem.representedObject as? String {
            menuItem.state = UserDefaults.standard.bool(forKey: key) ? .on : .off
        }
        return true
    }

    // MARK: Open Recent

    /// macOS 26 adds Open Recent to the File menu by itself. Where the system hasn't, add one.
    private func addOpenRecentIfMissing() {
        guard let file = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "File" })?.submenu else { return }
        let clear = #selector(NSDocumentController.clearRecentDocuments(_:))
        let present = file.items.contains { $0.submenu?.items.contains { $0.action == clear } == true }
        guard !present else { return }
        let recent = NSMenu(title: "Open Recent")
        recent.delegate = self
        let item = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        item.submenu = recent
        let open = file.items.firstIndex { $0.action == #selector(NSDocumentController.openDocument(_:)) } ?? 0
        file.insertItem(item, at: open + 1)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu.identifier == MainMenu.compareMenu { return fillCompareMenu(menu) }
        let urls = NSDocumentController.shared.recentDocumentURLs
        for url in urls {
            let item = menu.addItem(withTitle: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = (url.path as NSString).abbreviatingWithTildeInPath
        }
        if !urls.isEmpty { menu.addItem(.separator()) }
        menu.addItem(
            withTitle: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
    }

    /// Every other open document that is short enough to compare with the one in front.
    private func fillCompareMenu(_ menu: NSMenu) {
        let current = NSDocumentController.shared.currentDocument as? Document
        let others = NSDocumentController.shared.documents.compactMap { $0 as? Document }
            .filter { $0 !== current && $0.isComparable }
        if let current, current.isComparable {
            for other in others {
                let item = menu.addItem(
                    withTitle: other.displayName ?? "Untitled", action: #selector(Document.compareWithTab(_:)),
                    keyEquivalent: "")
                item.target = current
                item.representedObject = other
                item.toolTip = other.fileURL.map { ($0.path as NSString).abbreviatingWithTildeInPath }
            }
        }
        if menu.items.isEmpty {
            menu.addItem(withTitle: "No Other Tabs", action: nil, keyEquivalent: "").isEnabled = false
        }
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error { NSApp.presentError(error) }
        }
    }

    // MARK: Command line tool

    @objc func installCommandLineTool(_ sender: Any?) {
        guard let script = Bundle.main.url(forResource: "neutrino", withExtension: nil)?.path else { return }
        // Escape for an AppleScript string literal, then let `quoted form of` handle the shell.
        let literal = script.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
            do shell script "mkdir -p /usr/local/bin && rm -f /usr/local/bin/neutrino && cp " & quoted form of "\(literal)" & " /usr/local/bin/neutrino && chmod 755 /usr/local/bin/neutrino" with administrator privileges
            """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if (error?[NSAppleScript.errorNumber] as? Int) == -128 { return }  // password prompt cancelled
        let alert = NSAlert()
        if let error {
            alert.messageText = "Couldn't install the command line tool"
            alert.informativeText = error[NSAppleScript.errorMessage] as? String ?? ""
        } else {
            alert.messageText = "The neutrino command is installed"
            alert.informativeText = "Usage: neutrino file.txt"
        }
        alert.runModal()
    }

    // MARK: Updates

    @objc func checkForUpdates(_ sender: Any?) {
        UpdateChecker.check { [weak self] result in
            let alert = NSAlert()
            switch result {
            case .available(let release):
                self?.offer(release)
                return
            case .upToDate:
                alert.messageText = "You're up to date"
                alert.informativeText = "Neutrino \(UpdateChecker.currentVersion) is the latest version."
            case .failed(let message):
                alert.messageText = "Couldn't check for updates"
                alert.informativeText = message
            }
            alert.runModal()
        }
    }

    private func offer(_ release: UpdateChecker.Release) {
        let alert = NSAlert()
        alert.messageText = "Neutrino \(release.version) is available"
        alert.informativeText = "You have version \(UpdateChecker.currentVersion)."
        alert.addButton(withTitle: "View Release")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.url) }
    }
}
