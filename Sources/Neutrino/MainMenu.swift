import AppKit

/// The menu bar, built in code. Items without a target go to whichever view or window has focus.
enum MainMenu {
    /// The menu of other open documents to compare with; the app delegate fills it when it opens.
    static let compareMenu = NSUserInterfaceItemIdentifier("compare")

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
        add(file, "Open Quickly…", #selector(AppDelegate.openQuickly(_:)), "o", [.command, .option], target: delegate)
        add(file, "Open Path or Link at Caret", #selector(EditorWindowController.openPathAtCaret(_:)), "o", [.command, .control])
        // AppKit adds Open Recent after Open… by itself.
        add(file, "Reopen Closed Tab", #selector(DocumentController.reopenClosedTab(_:)), "t", [.command, .shift])
        file.addItem(.separator())
        add(file, "Close", #selector(NSWindow.performClose(_:)), "w")
        add(file, "Save", #selector(NSDocument.save(_:)), "s")
        add(file, "Save As…", #selector(NSDocument.saveAs(_:)), "s", [.command, .shift])
        add(file, "Revert to Saved", #selector(NSDocument.revertToSaved(_:)))
        add(file, "Read Only", #selector(EditorWindowController.toggleLock(_:)))
        add(file, "Compare with Saved", #selector(Document.compareWithSaved(_:)))
        let compare = NSMenu()
        compare.identifier = compareMenu
        compare.delegate = delegate
        file.addItem(withTitle: "Compare with Tab", action: nil, keyEquivalent: "").submenu = compare
        file.addItem(.separator())
        add(file, "Preview in MDReader", #selector(Document.previewInMDReader(_:)), "p", [.command, .option])
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
        add(edit, "Go to Symbol…", #selector(EditorWindowController.showSymbols(_:)), "o", [.command, .shift])
        add(edit, "Go to Last Edit", #selector(EditorWindowController.goToLastEdit(_:)), "-", [.control])
        add(edit, "Go to Matching Bracket", #selector(EditorTextView.goToMatchingBracket(_:)), "m", [.command, .shift])
        edit.addItem(.separator())

        let cursors = NSMenu()
        edit.addItem(withTitle: "Cursors", action: nil, keyEquivalent: "").submenu = cursors
        add(cursors, "Select Next Occurrence", #selector(EditorTextView.selectNextOccurrence(_:)), "d")
        add(cursors, "Add Cursor Above", #selector(EditorTextView.addCursorAbove(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command, .option])
        add(cursors, "Add Cursor Below", #selector(EditorTextView.addCursorBelow(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.command, .option])
        add(cursors, "Insert Numbers", #selector(EditorTextView.insertNumbers(_:)))
        add(cursors, "Split Selection into Lines", #selector(EditorTextView.splitSelectionIntoLines(_:)), "l", [.command, .shift])

        let lines = NSMenu()
        edit.addItem(withTitle: "Lines", action: nil, keyEquivalent: "").submenu = lines
        add(lines, "Shift Right", #selector(EditorTextView.shiftRight(_:)), "]")
        add(lines, "Shift Left", #selector(EditorTextView.shiftLeft(_:)), "[")
        add(lines, "Comment or Uncomment", #selector(EditorTextView.toggleComment(_:)), "/")
        lines.addItem(.separator())
        add(lines, "Move Up", #selector(EditorTextView.moveLinesUp(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command, .control])
        add(lines, "Move Down", #selector(EditorTextView.moveLinesDown(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.command, .control])
        add(lines, "Duplicate", #selector(EditorTextView.duplicateLines(_:)), "d", [.command, .shift])
        add(lines, "Delete", #selector(EditorTextView.deleteLines(_:)), "k", [.command, .shift])
        add(lines, "Join", #selector(EditorTextView.joinLines(_:)), "j", [.command])
        lines.addItem(.separator())
        add(lines, "Sort", #selector(EditorTextView.sortLines(_:)))
        add(lines, "Remove Duplicates", #selector(EditorTextView.removeDuplicateLines(_:)))

        let letters = NSMenu()
        edit.addItem(withTitle: "Convert Case", action: nil, keyEquivalent: "").submenu = letters
        add(letters, "Upper Case", #selector(NSResponder.uppercaseWord(_:)))
        add(letters, "Lower Case", #selector(NSResponder.lowercaseWord(_:)))
        add(letters, "Capitalize", #selector(NSResponder.capitalizeWord(_:)))

        let transform = NSMenu()
        edit.addItem(withTitle: "Transform", action: nil, keyEquivalent: "").submenu = transform
        add(transform, "Pretty-Print JSON", #selector(EditorTextView.prettyPrintJSON(_:)))
        add(transform, "Minify JSON", #selector(EditorTextView.minifyJSON(_:)))
        transform.addItem(.separator())
        add(transform, "Base64 Encode", #selector(EditorTextView.base64Encode(_:)))
        add(transform, "Base64 Decode", #selector(EditorTextView.base64Decode(_:)))
        add(transform, "URL Encode", #selector(EditorTextView.urlEncode(_:)))
        add(transform, "URL Decode", #selector(EditorTextView.urlDecode(_:)))
        transform.addItem(.separator())
        add(transform, "Indentation to Spaces", #selector(EditorTextView.indentationToSpaces(_:)))
        add(transform, "Indentation to Tabs", #selector(EditorTextView.indentationToTabs(_:)))

        let markdown = NSMenu()
        edit.addItem(withTitle: "Markdown", action: nil, keyEquivalent: "").submenu = markdown
        add(markdown, "Bold", #selector(EditorTextView.markdownBold(_:)), "b")
        add(markdown, "Italic", #selector(EditorTextView.markdownItalic(_:)), "i")

        let insert = NSMenu()
        edit.addItem(withTitle: "Insert", action: nil, keyEquivalent: "").submenu = insert
        add(insert, "Date", #selector(EditorTextView.insertDate(_:)))
        add(insert, "Date and Time", #selector(EditorTextView.insertDateAndTime(_:)))
        add(insert, "UUID", #selector(EditorTextView.insertUUID(_:)))

        add(edit, "Filter Through Command…", #selector(EditorWindowController.filterThroughCommand(_:)), "r", [.command, .option])
        edit.addItem(.separator())
        add(edit, "Complete Word", #selector(NSTextView.complete(_:)), "\u{1B}", [.option])
        add(edit, "Check Spelling While Typing", #selector(AppDelegate.toggleSetting(_:)), target: delegate)
            .representedObject = Prefs.checkSpelling

        // View
        let view = submenu("View", in: main)
        for (title, key) in [
            ("Wrap Lines", Prefs.wrapLines), ("Line Numbers", Prefs.lineNumbers),
            ("Invisible Characters", Prefs.showInvisibles), ("Highlight Current Line", Prefs.highlightCurrentLine),
        ] {
            let item = add(view, title, #selector(AppDelegate.toggleSetting(_:)), target: delegate)
            item.representedObject = key
        }
        add(view, "Split Editor", #selector(EditorWindowController.toggleSplit(_:)), "\\")
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
        window.addItem(.separator())
        for number in 1...9 {
            let title = number == 9 ? "Show Last Tab" : "Show Tab \(number)"
            add(window, title, #selector(AppDelegate.showTab(_:)), String(number), target: delegate).tag = number
        }
        // The delegate hides the tab items the front window has no tab for.
        window.delegate = delegate
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
