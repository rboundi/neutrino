import AppKit
import NeutrinoCore

/// The last things copied or cut in Neutrino, newest first, for Paste from History. They are
/// kept in memory only.
enum ClipboardHistory {
    private(set) static var entries: [(title: String, text: String)] = []
    private static let limit = 10
    /// A longer copy isn't kept: ten of them would hold a lot of memory.
    private static let longest = 1_000_000

    /// Takes what is on the clipboard now, right after a copy.
    static func noteCopy() {
        guard let copied = NSPasteboard.general.string(forType: .string), !copied.isEmpty,
            copied.utf16.count <= longest
        else { return }
        entries.removeAll { $0.text == copied }
        // The menu's title is made here, once, from the start of the text: its first line.
        let start = copied.prefix(400).trimmingCharacters(in: .whitespacesAndNewlines)
        let line = start.prefix { $0 != "\n" }
        let title = line.isEmpty ? "(blank)" : line.count > 60 ? line.prefix(60) + "…" : String(line)
        entries.insert((title, copied), at: 0)
        if entries.count > limit { entries.removeLast() }
    }
}

/// The abbreviations that Tab expands, kept in one text file the user edits.
final class SnippetStore {
    static let shared = SnippetStore()

    let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Neutrino/snippets.txt")
    private var loaded: [String: String] = [:]
    private var modified: Date?
    private var checked = Date.distantPast

    /// The snippets in the file, read again when the file has changed.
    var snippets: [String: String] {
        // Tab is pressed often; looking at the file once a second is enough.
        guard Date().timeIntervalSince(checked) > 1 else { return loaded }
        checked = Date()
        let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        guard date != modified else { return loaded }
        modified = date
        loaded = (try? String(contentsOf: file, encoding: .utf8)).map(Snippets.parse) ?? [:]
        return loaded
    }

    private static let sample = """
        Snippets for Neutrino. Type an abbreviation and press Tab to get its text.

        A line that starts with === and a name begins a snippet. The lines under it, up to the
        next ===, are its text. Start a line with a tab for one level of indentation. Text
        above the first === is not read.

        $1, $2 and so on are places the caret goes to, in that order, each time you press Tab;
        $0 is the last. ${1:name} is a place with text already in it, selected when you get there.
        Write \\$ for a dollar sign that should stay, as in \\$1.

        === todo
        TODO: $0

        === for
        for (let i = 0; i < ${1:count}; i++) {
        \t$0
        }

        """

    /// Opens the file in a tab, making it first if it isn't there.
    func edit() {
        if !FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Self.sample.write(to: file, atomically: true, encoding: .utf8)
        }
        NSDocumentController.shared.openDocument(withContentsOf: file, display: true) { _, _, error in
            if let error { NSApp.presentError(error) }
        }
    }
}
