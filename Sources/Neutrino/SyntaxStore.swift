import AppKit
import NeutrinoCore

/// Syntax files on this Mac and the list of those published in the repository.
///
/// Nothing is bundled. A syntax is a JSON file in Application Support, downloaded from the
/// repository's `syntaxes` folder or added by hand. It is read and compiled when the first
/// document needs it and dropped from memory when the last one using it closes.
final class SyntaxStore {
    static let shared = SyntaxStore()
    static let didChange = Notification.Name("SyntaxStoreDidChange")

    let directory: URL
    private let catalogCache: URL
    private var installedCache: [SyntaxInfo]?
    private var catalogList: [SyntaxInfo]?
    private var loaded: [String: Weak] = [:]
    private let session = URLSession(configuration: .ephemeral)

    private final class Weak {
        weak var syntax: CompiledSyntax?
        init(_ syntax: CompiledSyntax) { self.syntax = syntax }
    }

    static var repo: String {
        Bundle.main.object(forInfoDictionaryKey: "NeutrinoGitHubRepo") as? String ?? "rboundi/neutrino"
    }

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Neutrino")
        directory = support.appendingPathComponent("Syntaxes")
        catalogCache = support.appendingPathComponent("catalog.json")
    }

    // MARK: Installed syntaxes

    var installed: [SyntaxInfo] {
        if let installedCache { return installedCache }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let list = files.filter { $0.pathExtension == "json" }
            .compactMap { url -> SyntaxInfo? in
                guard let data = try? Data(contentsOf: url),
                    let info = try? JSONDecoder().decode(SyntaxInfo.self, from: data),
                    info.id == url.deletingPathExtension().lastPathComponent
                else { return nil }
                return info
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        installedCache = list
        return list
    }

    func isInstalled(_ id: String) -> Bool {
        installed.contains { $0.id == id }
    }

    /// The compiled syntax, shared by every document that uses it.
    func syntax(id: String) -> CompiledSyntax? {
        if let syntax = loaded[id]?.syntax { return syntax }
        guard SyntaxInfo.isValidID(id), let data = try? Data(contentsOf: file(for: id)),
            let syntax = try? CompiledSyntax(data: data)
        else { return nil }
        loaded = loaded.filter { $0.value.syntax != nil }
        loaded[id] = Weak(syntax)
        return syntax
    }

    /// How many syntaxes are compiled and in memory right now.
    var loadedCount: Int {
        loaded.values.filter { $0.syntax != nil }.count
    }

    func installedMatch(filename: String, firstLine: String) -> SyntaxInfo? {
        SyntaxCatalog.match(installed, filename: filename, firstLine: firstLine)
    }

    /// A published syntax that fits the file but isn't installed.
    func availableMatch(filename: String, firstLine: String) -> SyntaxInfo? {
        guard let hit = SyntaxCatalog.match(catalog, filename: filename, firstLine: firstLine),
            !isInstalled(hit.id)
        else { return nil }
        return hit
    }

    private func file(for id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }

    // MARK: Catalog

    /// Published syntaxes: the list fetched last, or the one that shipped with the app.
    var catalog: [SyntaxInfo] {
        if let catalogList { return catalogList }
        let bundled = Bundle.main.url(forResource: "syntaxes", withExtension: "json")
        let list = [catalogCache, bundled].compactMap { $0 }.lazy
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? JSONDecoder().decode(SyntaxCatalog.self, from: $0) }
            .first?.syntaxes ?? []
        catalogList = list
        return list
    }

    private func remote(_ name: String) -> URL {
        URL(string: "https://raw.githubusercontent.com/\(Self.repo)/main/syntaxes/\(name)")!
    }

    private func fetch(_ url: URL, completion: @escaping (Result<Data, Error>) -> Void) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("Neutrino/\(UpdateChecker.currentVersion)", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let result: Result<Data, Error>
            if let data, status == 200, data.count < 1 << 20 {
                result = .success(data)
            } else {
                result = .failure(error ?? SyntaxError(message: "GitHub returned status \(status)."))
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    func refreshCatalog(completion: @escaping (Error?) -> Void) {
        fetch(remote("index.json")) { [self] result in
            switch result {
            case .success(let data):
                guard let list = try? JSONDecoder().decode(SyntaxCatalog.self, from: data) else {
                    return completion(SyntaxError(message: "The syntax list couldn't be read."))
                }
                try? FileManager.default.createDirectory(
                    at: catalogCache.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: catalogCache, options: .atomic)
                catalogList = list.syntaxes
                NotificationCenter.default.post(name: Self.didChange, object: self)
                completion(nil)
            case .failure(let error):
                completion(error)
            }
        }
    }

    // MARK: Installing and removing

    func install(_ info: SyntaxInfo, completion: @escaping (Error?) -> Void) {
        guard SyntaxInfo.isValidID(info.id) else {
            return completion(SyntaxError(message: "Invalid id “\(info.id)”."))
        }
        fetch(remote("\(info.id).json")) { [self] result in
            do {
                try store(result.get(), expectedID: info.id)
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    /// Installs a syntax file from disk, for syntaxes that aren't in the repository.
    func install(fileAt url: URL) throws {
        try store(Data(contentsOf: url), expectedID: nil)
    }

    private func store(_ data: Data, expectedID: String?) throws {
        // Compiling checks every rule, so a broken file never reaches the folder.
        let syntax = try CompiledSyntax(data: data)
        let id = syntax.definition.id
        if let expectedID, expectedID != id {
            throw SyntaxError(message: "The file is for “\(id)”, not “\(expectedID)”.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: file(for: id), options: .atomic)
        changed(id)
    }

    func remove(_ id: String) {
        guard SyntaxInfo.isValidID(id) else { return }
        try? FileManager.default.removeItem(at: file(for: id))
        changed(id)
    }

    private func changed(_ id: String) {
        installedCache = nil
        loaded[id] = nil
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    func showFolder() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }
}
