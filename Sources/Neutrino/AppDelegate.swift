import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    static let shared = AppDelegate()

    /// Files to reopen from the last session, read before anything else is opened.
    private var filesToRestore: [URL] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        Prefs.register()
        NSApp.appearance = Prefs.appearanceMode.nsAppearance
        NSApp.mainMenu = MainMenu.build(delegate: self)
        NSWindow.allowsAutomaticWindowTabbing = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(defaultsChanged), name: UserDefaults.didChangeNotification, object: nil)

        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Prefs.reopenDocuments) {
            filesToRestore = (defaults.stringArray(forKey: Prefs.openDocuments) ?? [])
                .map { URL(fileURLWithPath: $0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        for url in filesToRestore {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        }
        filesToRestore = []
        UpdateChecker.checkIfDue { [weak self] release in self?.offer(release) }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        // At launch the restored files take the place of the empty window.
        filesToRestore.isEmpty
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let paths = NSDocumentController.shared.documents.compactMap { $0.fileURL?.path }
        UserDefaults.standard.set(paths, forKey: Prefs.openDocuments)
        return .terminateNow
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    @objc private func defaultsChanged() {
        DispatchQueue.main.async {
            let appearance = Prefs.appearanceMode.nsAppearance
            if NSApp.appearance != appearance { NSApp.appearance = appearance }
        }
    }

    // MARK: Menu commands

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }

    @objc func toggleSetting(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
    }

    @objc func changeFontSize(_ sender: NSMenuItem) {
        let defaults = UserDefaults.standard
        let size = sender.tag == 0 ? Prefs.defaultFontSize : defaults.double(forKey: Prefs.fontSize) + Double(sender.tag)
        defaults.set(min(max(size, 8), 48), forKey: Prefs.fontSize)
    }

    @objc func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error { NSApp.presentError(error) }
        }
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

    /// Fills File → Open Recent each time it opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let urls = NSDocumentController.shared.recentDocumentURLs
        for url in urls {
            let item = menu.addItem(withTitle: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = (url.path as NSString).abbreviatingWithTildeInPath
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
        }
        if !urls.isEmpty { menu.addItem(.separator()) }
        let clear = menu.addItem(
            withTitle: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
        clear.isEnabled = !urls.isEmpty
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
