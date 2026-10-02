import AppKit
import NeutrinoCore

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
        next ===, are its text. $0 is where the caret goes. Start a line with a tab for one
        level of indentation. Text above the first === is not read.

        === todo
        TODO: $0

        === for
        for (let i = 0; i < $0; i++) {
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
