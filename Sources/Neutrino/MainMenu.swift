import AppKit

/// The menu bar, built in code. Items without a target go to whichever view or window has focus.
enum MainMenu {
    /// The menu of other open documents to compare with; the app delegate fills it when it opens.
    static let compareMenu = NSUserInterfaceItemIdentifier("compare")
    /// The menu of earlier copies to paste; filled the same way.
    static let historyMenu = NSUserInterfaceItemIdentifier("history")

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

        let up = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        let down = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        let right = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        let f2 = String(UnicodeScalar(NSF2FunctionKey)!)
        func group(_ title: String, in menu: NSMenu) -> NSMenu {
            let group = NSMenu()
            menu.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = group
            return group
        }

        // File
        let file = submenu("File", in: main)
        add(file, "New", #selector(NSDocumentController.newDocument(_:)), "n")
        add(file, "New from Clipboard", #selector(DocumentController.newFromClipboard(_:)), "n", [.command, .shift])
        add(file, "Open…", #selector(NSDocumentController.openDocument(_:)), "o")
        // AppKit adds Open Recent after Open… by itself.
        add(file, "Open Quickly…", #selector(AppDelegate.openQuickly(_:)), "o", [.command, .option], target: delegate)
        add(file, "Reopen Closed Tab", #selector(DocumentController.reopenClosedTab(_:)), "t", [.command, .shift])
        file.addItem(.separator())
        add(file, "Close", #selector(NSWindow.performClose(_:)), "w")
        add(file, "Close Other Tabs", #selector(AppDelegate.closeOtherTabs(_:)), "w", [.command, .option], target: delegate)
        add(file, "Close Tabs to the Right", #selector(AppDelegate.closeTabsToTheRight(_:)), target: delegate)
        file.addItem(.separator())
        add(file, "Save", #selector(NSDocument.save(_:)), "s")
        add(file, "Save As…", #selector(NSDocument.saveAs(_:)), "s", [.command, .shift])
        add(file, "Save All", #selector(AppDelegate.saveAll(_:)), "s", [.command, .option], target: delegate)
        add(file, "Duplicate", #selector(NSDocument.duplicate(_:)))
        add(file, "Rename…", #selector(NSDocument.rename(_:)))
        add(file, "Move To…", #selector(NSDocument.move(_:)))
        add(file, "Revert to Saved", #selector(NSDocument.revertToSaved(_:)))
        add(file, "Read Only", #selector(EditorWindowController.toggleLock(_:)))
        file.addItem(.separator())
        let compare = group("Compare", in: file)
        add(compare, "With Saved", #selector(Document.compareWithSaved(_:)))
        add(compare, "With Clipboard", #selector(Document.compareWithClipboard(_:)))
        add(compare, "With Git HEAD", #selector(Document.compareWithGitHead(_:)))
        let tabs = group("With Tab", in: compare)
        tabs.identifier = compareMenu
        tabs.delegate = delegate
        add(file, "Reveal in Finder", #selector(Document.revealInFinder(_:)), "r", [.command, .shift])
        add(file, "Copy Path", #selector(Document.copyPath(_:)), "c", [.command, .control])
        add(file, "Open Terminal Here", #selector(Document.openTerminalHere(_:)))
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
        add(edit, "Paste and Match Indentation", #selector(EditorTextView.pasteAndIndent(_:)), "v", [.command, .option, .shift])
        let history = group("Paste from History", in: edit)
        history.identifier = historyMenu
        history.delegate = delegate
        add(edit, "Delete", #selector(NSText.delete(_:)))
        add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())

        let find = group("Find", in: edit)
        add(find, "Find and Replace…", #selector(EditorWindowController.showFind(_:)), "f")
        add(find, "Find Next", #selector(EditorWindowController.findNext(_:)), "g")
        add(find, "Find Previous", #selector(EditorWindowController.findPrevious(_:)), "g", [.command, .shift])
        add(find, "Find All", #selector(EditorWindowController.findAll(_:)), "f", [.command, .control])
        add(find, "Use Selection for Find", #selector(EditorWindowController.useSelectionForFind(_:)), "e")
        add(find, "Find in Open Documents…", #selector(EditorWindowController.showFindInDocuments(_:)), "f", [.command, .shift])
        find.addItem(.separator())
        add(find, "Keep Matching Lines", #selector(EditorWindowController.keepMatchingLines(_:)))
        add(find, "Delete Matching Lines", #selector(EditorWindowController.deleteMatchingLines(_:)))

        let selection = group("Selection", in: edit)
        add(selection, "Expand", #selector(EditorTextView.expandSelection(_:)), up, [.control, .shift])
        add(selection, "Shrink", #selector(EditorTextView.shrinkSelection(_:)), down, [.control, .shift])
        selection.addItem(.separator())
        add(selection, "Select Next Occurrence", #selector(EditorTextView.selectNextOccurrence(_:)), "d")
        add(selection, "Select All Occurrences", #selector(EditorTextView.selectAllOccurrences(_:)), "g", [.command, .control])
        add(selection, "Add Cursor Above", #selector(EditorTextView.addCursorAbove(_:)), up, [.command, .option])
        add(selection, "Add Cursor Below", #selector(EditorTextView.addCursorBelow(_:)), down, [.command, .option])
        add(selection, "Split into Lines", #selector(EditorTextView.splitSelectionIntoLines(_:)), "l", [.command, .shift])
        selection.addItem(.separator())
        add(selection, "Insert Numbers at Cursors", #selector(EditorTextView.insertNumbers(_:)))
        add(selection, "Increase Number", #selector(EditorTextView.increaseNumber(_:)), up, [.control, .option])
        add(selection, "Decrease Number", #selector(EditorTextView.decreaseNumber(_:)), down, [.control, .option])

        let lines = group("Lines", in: edit)
        add(lines, "Shift Right", #selector(EditorTextView.shiftRight(_:)), "]")
        add(lines, "Shift Left", #selector(EditorTextView.shiftLeft(_:)), "[")
        add(lines, "Comment or Uncomment", #selector(EditorTextView.toggleComment(_:)), "/")
        lines.addItem(.separator())
        add(lines, "Move Up", #selector(EditorTextView.moveLinesUp(_:)), up, [.command, .control])
        add(lines, "Move Down", #selector(EditorTextView.moveLinesDown(_:)), down, [.command, .control])
        add(lines, "Duplicate", #selector(EditorTextView.duplicateLines(_:)), "d", [.command, .shift])
        add(lines, "Delete", #selector(EditorTextView.deleteLines(_:)), "k", [.command, .shift])
        add(lines, "Join", #selector(EditorTextView.joinLines(_:)), "j", [.command])
        lines.addItem(.separator())
        add(lines, "Sort", #selector(EditorTextView.sortLines(_:)))
        add(lines, "Sort by Number", #selector(EditorTextView.sortLinesByNumber(_:)))
        add(lines, "Reverse", #selector(EditorTextView.reverseLines(_:)))
        add(lines, "Remove Duplicates", #selector(EditorTextView.removeDuplicateLines(_:)))
        add(lines, "Delete Blank Lines", #selector(EditorTextView.deleteBlankLines(_:)))
        add(lines, "Trim Trailing Spaces", #selector(EditorTextView.trimTrailingSpaces(_:)))
        lines.addItem(.separator())
        add(lines, "Align…", #selector(EditorWindowController.alignLines(_:)))
        add(lines, "Rewrap Paragraph", #selector(EditorTextView.rewrapParagraph(_:)), "q", [.control])
        add(lines, "Indentation to Spaces", #selector(EditorTextView.indentationToSpaces(_:)))
        add(lines, "Indentation to Tabs", #selector(EditorTextView.indentationToTabs(_:)))

        let transform = group("Transform", in: edit)
        add(transform, "Upper Case", #selector(NSResponder.uppercaseWord(_:)))
        add(transform, "Lower Case", #selector(NSResponder.lowercaseWord(_:)))
        add(transform, "Capitalize", #selector(NSResponder.capitalizeWord(_:)))
        add(transform, "Change Name Style", #selector(EditorTextView.changeNameStyle(_:)), "c", [.control, .shift])
        transform.addItem(.separator())
        add(transform, "Pretty-Print JSON", #selector(EditorTextView.prettyPrintJSON(_:)))
        add(transform, "Minify JSON", #selector(EditorTextView.minifyJSON(_:)))
        add(transform, "Sort JSON Keys", #selector(EditorTextView.sortJSONKeys(_:)))
        add(transform, "Escape JSON String", #selector(EditorTextView.jsonEscape(_:)))
        add(transform, "Unescape JSON String", #selector(EditorTextView.jsonUnescape(_:)))
        transform.addItem(.separator())
        add(transform, "Base64 Encode", #selector(EditorTextView.base64Encode(_:)))
        add(transform, "Base64 Decode", #selector(EditorTextView.base64Decode(_:)))
        add(transform, "URL Encode", #selector(EditorTextView.urlEncode(_:)))
        add(transform, "URL Decode", #selector(EditorTextView.urlDecode(_:)))
        add(transform, "Encode HTML Entities", #selector(EditorTextView.htmlEncode(_:)))
        add(transform, "Decode HTML Entities", #selector(EditorTextView.htmlDecode(_:)))
        add(transform, "Timestamp to Date and Back", #selector(EditorTextView.convertTimestamp(_:)))
        add(transform, "Hex to Decimal and Back", #selector(EditorTextView.convertHex(_:)))
        transform.addItem(.separator())
        add(transform, "Zap Gremlins", #selector(EditorTextView.zapGremlins(_:)))
        add(transform, "Straighten Quotes", #selector(EditorTextView.straightenQuotes(_:)))
        transform.addItem(.separator())
        add(transform, "Evaluate Expression", #selector(EditorTextView.evaluateExpression(_:)), "=", [.control])
        add(transform, "Copy JSON Path", #selector(EditorWindowController.copyJSONPath(_:)))
        add(transform, "Copy SHA-256", #selector(EditorWindowController.copySHA256(_:)))
        add(transform, "Filter Through Command…", #selector(EditorWindowController.filterThroughCommand(_:)), "r", [.command, .option])

        let insert = group("Insert", in: edit)
        add(insert, "Date", #selector(EditorTextView.insertDate(_:)))
        add(insert, "Date and Time", #selector(EditorTextView.insertDateAndTime(_:)))
        add(insert, "UUID", #selector(EditorTextView.insertUUID(_:)))
        add(insert, "Closing Tag", #selector(EditorTextView.closeTag(_:)), ".", [.command, .option])
        insert.addItem(.separator())
        add(insert, "Edit Snippets…", #selector(AppDelegate.editSnippets(_:)), target: delegate)

        let markdown = group("Markdown", in: edit)
        add(markdown, "Bold", #selector(EditorTextView.markdownBold(_:)), "b")
        add(markdown, "Italic", #selector(EditorTextView.markdownItalic(_:)), "i")
        add(markdown, "Link", #selector(EditorTextView.markdownLink(_:)), "k")
        add(markdown, "Toggle Checkbox", #selector(EditorTextView.markdownCheckbox(_:)))
        add(markdown, "Format Table", #selector(EditorTextView.markdownFormatTable(_:)))

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
        view.addItem(.separator())
        add(view, "Split Editor", #selector(EditorWindowController.toggleSplit(_:)), "\\")
        add(view, "Show as Table", #selector(EditorWindowController.toggleTable(_:)), "t", [.command, .option])
        view.addItem(.separator())
        add(view, "Fold", #selector(EditorWindowController.foldBlock(_:)), left, [.command, .option])
        add(view, "Unfold", #selector(EditorWindowController.unfoldBlock(_:)), right, [.command, .option])
        add(view, "Fold All", #selector(EditorWindowController.foldLevel(_:)), left, [.command, .option, .shift]).tag = 1
        add(view, "Fold Level 2", #selector(EditorWindowController.foldLevel(_:))).tag = 2
        add(view, "Fold Level 3", #selector(EditorWindowController.foldLevel(_:))).tag = 3
        add(view, "Unfold All", #selector(EditorWindowController.unfoldAll(_:)), right, [.command, .option, .shift])
        view.addItem(.separator())
        add(view, "Bigger", #selector(AppDelegate.changeFontSize(_:)), "+", target: delegate).tag = 1
        add(view, "Smaller", #selector(AppDelegate.changeFontSize(_:)), "-", target: delegate).tag = -1
        add(view, "Default Size", #selector(AppDelegate.changeFontSize(_:)), "0", target: delegate).tag = 0
        view.addItem(.separator())
        add(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control, .shift])

        // Go
        let go = submenu("Go", in: main)
        add(go, "Go to Line…", #selector(EditorWindowController.goToLine(_:)), "l")
        add(go, "Go to Symbol…", #selector(EditorWindowController.showSymbols(_:)), "o", [.command, .shift])
        add(go, "Go to Matching Bracket or Tag", #selector(EditorTextView.goToMatchingBracket(_:)), "m", [.command, .shift])
        add(go, "Go to Last Edit", #selector(EditorWindowController.goToLastEdit(_:)), "-", [.control])
        add(go, "Open Path or Link at Caret", #selector(EditorWindowController.openPathAtCaret(_:)), "o", [.command, .control])
        add(go, "Next Change", #selector(EditorWindowController.nextChange(_:)), down, [.command, .option, .shift])
        add(go, "Previous Change", #selector(EditorWindowController.previousChange(_:)), up, [.command, .option, .shift])
        go.addItem(.separator())
        add(go, "Toggle Bookmark", #selector(EditorWindowController.toggleBookmark(_:)), f2)
        add(go, "Next Bookmark", #selector(EditorWindowController.nextBookmark(_:)), f2, [])
        add(go, "Previous Bookmark", #selector(EditorWindowController.previousBookmark(_:)), f2, [.shift])
        add(go, "Clear Bookmarks", #selector(EditorWindowController.clearBookmarks(_:)))

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
