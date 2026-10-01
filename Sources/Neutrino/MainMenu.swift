import AppKit

/// The menu bar, built in code. Items without a target go to whichever view or window has focus.
enum MainMenu {
    static func build(delegate: AppDelegate) -> NSMenu {
        let main = NSMenu()

        // Neutrino
        let app = submenu("Neutrino", in: main)
        add(app, "About Neutrino", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        add(app, "Check for Updates…", #selector(AppDelegate.checkForUpdates(_:)), target: delegate)
        app.addItem(.separator())
        add(app, "Settings…", #selector(AppDelegate.showSettings(_:)), ",", target: delegate)
        add(app, "Install Command Line Tool…", #selector(AppDelegate.installCommandLineTool(_:)), target: delegate)
        app.addItem(.separator())
        let services = NSMenu()
        app.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = services
        NSApp.servicesMenu = services
        app.addItem(.separator())
        add(app, "Hide Neutrino", #selector(NSApplication.hide(_:)), "h")
        add(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        add(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator())
        add(app, "Quit Neutrino", #selector(NSApplication.terminate(_:)), "q")

        // File
        let file = submenu("File", in: main)
        add(file, "New", #selector(NSDocumentController.newDocument(_:)), "n")
        add(file, "Open…", #selector(NSDocumentController.openDocument(_:)), "o")
        let recent = NSMenu()
        recent.delegate = delegate
        file.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "").submenu = recent
        file.addItem(.separator())
        add(file, "Close", #selector(NSWindow.performClose(_:)), "w")
        add(file, "Save", #selector(NSDocument.save(_:)), "s")
        add(file, "Save As…", #selector(NSDocument.saveAs(_:)), "s", [.command, .shift])
        add(file, "Revert to Saved", #selector(NSDocument.revertToSaved(_:)))
        file.addItem(.separator())
        add(file, "Print…", #selector(NSDocument.printDocument(_:)), "p")

        // Edit
        let edit = submenu("Edit", in: main)
        add(edit, "Undo", Selector(("undo:")), "z")
        add(edit, "Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        add(edit, "Cut", #selector(NSText.cut(_:)), "x")
        add(edit, "Copy", #selector(NSText.copy(_:)), "c")
        add(edit, "Paste", #selector(NSText.paste(_:)), "v")
        add(edit, "Delete", #selector(NSText.delete(_:)))
        add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        let find = NSMenu()
        edit.addItem(withTitle: "Find", action: nil, keyEquivalent: "").submenu = find
        add(find, "Find and Replace…", #selector(EditorWindowController.showFind(_:)), "f")
        add(find, "Find Next", #selector(EditorWindowController.findNext(_:)), "g")
        add(find, "Find Previous", #selector(EditorWindowController.findPrevious(_:)), "g", [.command, .shift])
        add(find, "Find All", #selector(EditorWindowController.findAll(_:)), "f", [.command, .control])
        add(find, "Use Selection for Find", #selector(EditorWindowController.useSelectionForFind(_:)), "e")
        add(edit, "Go to Line…", #selector(EditorWindowController.goToLine(_:)), "l")
        edit.addItem(.separator())
        add(edit, "Shift Right", #selector(EditorTextView.shiftRight(_:)), "]")
        add(edit, "Shift Left", #selector(EditorTextView.shiftLeft(_:)), "[")
        add(edit, "Comment or Uncomment", #selector(EditorTextView.toggleComment(_:)), "/")

        // View
        let view = submenu("View", in: main)
        for (title, key) in [
            ("Wrap Lines", Prefs.wrapLines), ("Line Numbers", Prefs.lineNumbers),
            ("Invisible Characters", Prefs.showInvisibles), ("Highlight Current Line", Prefs.highlightCurrentLine),
        ] {
            let item = add(view, title, #selector(AppDelegate.toggleSetting(_:)), target: delegate)
            item.representedObject = key
        }
        view.addItem(.separator())
        add(view, "Bigger", #selector(AppDelegate.changeFontSize(_:)), "+", target: delegate).tag = 1
        add(view, "Smaller", #selector(AppDelegate.changeFontSize(_:)), "-", target: delegate).tag = -1
        add(view, "Default Size", #selector(AppDelegate.changeFontSize(_:)), "0", target: delegate).tag = 0
        view.addItem(.separator())
        add(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control, .shift])

        // Window
        let window = submenu("Window", in: main)
        add(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(window, "Zoom", #selector(NSWindow.performZoom(_:)))
        window.addItem(.separator())
        add(window, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        NSApp.windowsMenu = window

        // Help
        let help = submenu("Help", in: main)
        add(help, "Neutrino on GitHub", #selector(AppDelegate.openRepository(_:)), target: delegate)
        NSApp.helpMenu = help

        return main
    }

    private static func submenu(_ title: String, in main: NSMenu) -> NSMenu {
        let menu = NSMenu(title: title)
        let item = main.addItem(withTitle: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return menu
    }

    @discardableResult
    private static func add(
        _ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil
    ) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        return item
    }
}
