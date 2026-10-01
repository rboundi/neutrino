import AppKit
import NeutrinoCore

/// Syntax files on this Mac and the list of those published in the repository.
///
/// A syntax is read and compiled when the first document needs it and dropped from memory
/// when the last one using it closes.
final class SyntaxStore {
    static let shared = SyntaxStore()
    static let didChange = Notification.Name("SyntaxStoreDidChange")

    let files = PackageFolder<SyntaxInfo>(
        name: "syntaxes", folder: "Syntaxes", didChange: SyntaxStore.didChange,
        decodeCatalog: { (try? JSONDecoder().decode(SyntaxCatalog.self, from: $0))?.syntaxes },
        validate: { try CompiledSyntax(data: $0).definition.id },
        label: \.name)

    private var loaded: [String: Weak] = [:]

    private final class Weak {
        weak var syntax: CompiledSyntax?
        init(_ syntax: CompiledSyntax) { self.syntax = syntax }
    }

    private init() {
        files.onChange = { [weak self] id in self?.loaded[id] = nil }
    }

    var installed: [SyntaxInfo] { files.installed }
    var catalog: [SyntaxInfo] { files.catalog }

    /// The compiled syntax, shared by every document that uses it.
    func syntax(id: String) -> CompiledSyntax? {
        if let syntax = loaded[id]?.syntax { return syntax }
        guard let data = files.data(for: id), let syntax = try? CompiledSyntax(data: data) else { return nil }
        loaded = loaded.filter { $0.value.syntax != nil }
        loaded[id] = Weak(syntax)
        return syntax
    }

    func installedMatch(filename: String, firstLine: String) -> SyntaxInfo? {
        SyntaxCatalog.match(installed, filename: filename, firstLine: firstLine)
    }

    /// A published syntax that fits the file but isn't installed.
    func availableMatch(filename: String, firstLine: String) -> SyntaxInfo? {
        guard let hit = SyntaxCatalog.match(catalog, filename: filename, firstLine: firstLine),
            !files.isInstalled(hit.id)
        else { return nil }
        return hit
    }
}
