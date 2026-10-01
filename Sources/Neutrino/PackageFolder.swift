import AppKit
import NeutrinoCore

/// A folder of small JSON files that are installed on demand: syntaxes or themes.
///
/// Nothing is bundled. Each file lives in Application Support, downloaded from the matching
/// folder of the repository or added by hand, and is only read when something needs it.
final class PackageFolder<Info: Codable & Identifiable> where Info.ID == String {
    /// The folder name in the repository, also used for the catalog shipped with the app.
    let name: String
    let directory: URL
    let didChange: Notification.Name
    /// Called with the id of a file that was installed, replaced or removed.
    var onChange: (String) -> Void = { _ in }

    private let catalogCache: URL
    private let decodeCatalog: (Data) -> [Info]?
    private let validate: (Data) throws -> String
    private let label: (Info) -> String
    private var installedCache: [Info]?
    private var catalogList: [Info]?
    private let session = URLSession(configuration: .ephemeral)

    static var repo: String {
        Bundle.main.object(forInfoDictionaryKey: "NeutrinoGitHubRepo") as? String ?? "rboundi/neutrino"
    }

    /// - Parameters:
    ///   - validate: checks a file before it is stored and returns its id; throws to refuse it.
    ///   - label: the name to sort by.
    init(
        name: String, folder: String, didChange: Notification.Name, decodeCatalog: @escaping (Data) -> [Info]?,
        validate: @escaping (Data) throws -> String, label: @escaping (Info) -> String
    ) {
        self.name = name
        self.didChange = didChange
        self.decodeCatalog = decodeCatalog
        self.validate = validate
        self.label = label
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Neutrino")
        directory = support.appendingPathComponent(folder)
        catalogCache = support.appendingPathComponent(name == "syntaxes" ? "catalog.json" : "\(name)-catalog.json")
    }

    // MARK: Installed files

    var installed: [Info] {
        if let installedCache { return installedCache }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let list = files.filter { $0.pathExtension == "json" }
            .compactMap { url -> Info? in
                guard let data = try? Data(contentsOf: url),
                    let info = try? JSONDecoder().decode(Info.self, from: data),
                    info.id == url.deletingPathExtension().lastPathComponent
                else { return nil }
                return info
            }
            .sorted { label($0).localizedCaseInsensitiveCompare(label($1)) == .orderedAscending }
        installedCache = list
        return list
    }

    func isInstalled(_ id: String) -> Bool {
        installed.contains { $0.id == id }
    }

    func data(for id: String) -> Data? {
        guard SyntaxInfo.isValidID(id) else { return nil }
        return try? Data(contentsOf: file(for: id))
    }

    private func file(for id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }

    // MARK: Catalog

    /// Published files: the list fetched last or the one that shipped with the app, whichever
    /// is newer, so an updated app isn't held back by an old download.
    var catalog: [Info] {
        if let catalogList { return catalogList }
        let bundled = Bundle.main.url(forResource: name, withExtension: "json")
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        let list = [catalogCache, bundled].compactMap { $0 }.sorted { modified($0) > modified($1) }.lazy
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { self.decodeCatalog($0) }
            .first ?? []
        catalogList = list
        return list
    }

    private func remote(_ file: String) -> URL {
        URL(string: "https://raw.githubusercontent.com/\(Self.repo)/main/\(name)/\(file)")!
    }

    private func fetch(_ url: URL, completion: @escaping (Result<Data, Error>) -> Void) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("Neutrino/\(UpdateChecker.currentVersion)", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let result: Result<Data, Error>
            if let data, status == 200 {
                result = data.count < 1 << 20 ? .success(data)
                    : .failure(SyntaxError(message: "The file is larger than expected."))
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
                guard let list = decodeCatalog(data) else {
                    return completion(SyntaxError(message: "The list couldn't be read."))
                }
                try? FileManager.default.createDirectory(
                    at: catalogCache.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: catalogCache, options: .atomic)
                catalogList = list
                NotificationCenter.default.post(name: didChange, object: nil)
                completion(nil)
            case .failure(let error):
                completion(error)
            }
        }
    }

    // MARK: Installing and removing

    func install(id: String, completion: @escaping (Error?) -> Void) {
        guard SyntaxInfo.isValidID(id) else {
            return completion(SyntaxError(message: "Invalid id “\(id)”."))
        }
        fetch(remote("\(id).json")) { [self] result in
            do {
                try store(result.get(), expectedID: id)
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    /// Installs a file from disk, for ones that aren't in the repository.
    func install(fileAt url: URL) throws {
        try store(Data(contentsOf: url), expectedID: nil)
    }

    private func store(_ data: Data, expectedID: String?) throws {
        // Validation checks the whole file, so a broken one never reaches the folder.
        let id = try validate(data)
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
        onChange(id)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    func showFolder() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }
}
