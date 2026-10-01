import AppKit
import NeutrinoCore
import SwiftUI

/// The Settings window: one short page per toolbar tab.
final class SettingsWindowController: NSWindowController {
    enum Tab: Int {
        case general, editor, syntaxes
    }

    static let shared = SettingsWindowController()

    private let tabs = NSTabViewController()

    private init() {
        tabs.tabStyle = .toolbar
        let pages: [(String, String, AnyView)] = [
            ("General", "gearshape", AnyView(GeneralSettings())),
            ("Editor", "text.cursor", AnyView(EditorSettings())),
            ("Syntaxes", "curlybraces", AnyView(SyntaxSettings())),
        ]
        for (title, symbol, view) in pages {
            let host = NSHostingController(rootView: view)
            host.sizingOptions = .preferredContentSize
            host.title = title
            let item = NSTabViewItem(viewController: host)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.title = "Settings"
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(tab: Tab? = nil) {
        if let tab { tabs.selectedTabViewItemIndex = tab.rawValue }
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct Page<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .frame(width: 480)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettings: View {
    @AppStorage(Prefs.appearance) private var appearance = AppearanceMode.system.rawValue
    @AppStorage(Prefs.reopenDocuments) private var reopenDocuments = true
    @AppStorage(Prefs.checkForUpdates) private var checkForUpdates = true

    var body: some View {
        Page {
            Section {
                Picker("Theme", selection: $appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
            }
            Section {
                Toggle("Reopen documents from last session", isOn: $reopenDocuments)
                Toggle("Check for updates", isOn: $checkForUpdates)
                HStack {
                    Text("Command line tool")
                    Spacer()
                    Text("neutrino file.txt").font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                    Button("Install…") { AppDelegate.shared.installCommandLineTool(nil) }
                }
            }
        }
    }
}

private struct EditorSettings: View {
    @AppStorage(Prefs.fontName) private var fontName = ""
    @AppStorage(Prefs.fontSize) private var fontSize = Prefs.defaultFontSize
    @AppStorage(Prefs.tabWidth) private var tabWidth = 4
    @AppStorage(Prefs.insertSpaces) private var insertSpaces = true
    @AppStorage(Prefs.wrapLines) private var wrapLines = true
    @AppStorage(Prefs.lineNumbers) private var lineNumbers = true
    @AppStorage(Prefs.showInvisibles) private var showInvisibles = false
    @AppStorage(Prefs.highlightCurrentLine) private var highlightCurrentLine = true
    @AppStorage(Prefs.autoIndent) private var autoIndent = true
    @AppStorage(Prefs.autoCloseBrackets) private var autoCloseBrackets = true
    @AppStorage(Prefs.trimTrailingWhitespace) private var trimTrailingWhitespace = false
    @AppStorage(Prefs.ensureFinalNewline) private var ensureFinalNewline = false

    /// Fixed-width font families on this Mac.
    private static let families: [String] = {
        let manager = NSFontManager.shared
        let names = manager.availableFontNames(with: .fixedPitchFontMask) ?? []
        return Array(Set(names.compactMap { NSFont(name: $0, size: 12)?.familyName })).sorted()
    }()

    var body: some View {
        Page {
            Section {
                Picker("Font", selection: $fontName) {
                    Text("System Monospaced").tag("")
                    ForEach(Self.families, id: \.self) { Text($0).tag($0) }
                }
                HStack {
                    Text("Size")
                    Spacer()
                    Text("\(Int(fontSize)) pt").monospacedDigit().foregroundStyle(.secondary)
                    Stepper("", value: $fontSize, in: 8...48, step: 1).labelsHidden()
                }
            }
            Section("Indentation") {
                Picker("Indent with", selection: $insertSpaces) {
                    Text("Spaces").tag(true)
                    Text("Tabs").tag(false)
                }
                HStack {
                    Text("Tab width")
                    Spacer()
                    Text("\(tabWidth)").monospacedDigit().foregroundStyle(.secondary)
                    Stepper("", value: $tabWidth, in: 1...16).labelsHidden()
                }
                Toggle("Keep the indentation on new lines", isOn: $autoIndent)
                Toggle("Close brackets and quotes", isOn: $autoCloseBrackets)
            }
            Section("Display") {
                Toggle("Wrap lines", isOn: $wrapLines)
                Toggle("Line numbers", isOn: $lineNumbers)
                Toggle("Highlight the current line", isOn: $highlightCurrentLine)
                Toggle("Show invisible characters", isOn: $showInvisibles)
            }
            Section("When saving") {
                Toggle("Remove trailing spaces", isOn: $trimTrailingWhitespace)
                Toggle("End the file with a line break", isOn: $ensureFinalNewline)
            }
        }
    }
}

/// The syntax list shown in Settings, kept in step with `SyntaxStore`.
private final class SyntaxListModel: ObservableObject {
    struct Row: Identifiable {
        var info: SyntaxInfo
        var installedVersion: Int?
        var published: Bool
        var id: String { info.id }
    }

    @Published var rows: [Row] = []
    @Published var busy: Set<String> = []
    @Published var message = ""
    @Published var refreshing = false

    private var observer: NSObjectProtocol?

    init() {
        reload()
        observer = NotificationCenter.default.addObserver(
            forName: SyntaxStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in self?.reload() }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func reload() {
        let store = SyntaxStore.shared
        let installed = Dictionary(uniqueKeysWithValues: store.installed.map { ($0.id, $0) })
        var rows = store.catalog.map { Row(info: $0, installedVersion: installed[$0.id]?.version, published: true) }
        let published = Set(store.catalog.map(\.id))
        // Syntaxes added by hand that the repository doesn't have.
        rows += store.installed.filter { !published.contains($0.id) }
            .map { Row(info: $0, installedVersion: $0.version, published: false) }
        self.rows = rows.sorted { $0.info.name.localizedCaseInsensitiveCompare($1.info.name) == .orderedAscending }
    }

    func refresh() {
        refreshing = true
        SyntaxStore.shared.refreshCatalog { [weak self] error in
            self?.refreshing = false
            self?.message = error.map { "Couldn't load the list: \($0.localizedDescription)" } ?? ""
        }
    }

    func install(_ row: Row) {
        busy.insert(row.id)
        SyntaxStore.shared.install(row.info) { [weak self] error in
            self?.busy.remove(row.id)
            self?.message = error.map { "Couldn't install \(row.info.name): \($0.localizedDescription)" } ?? ""
        }
    }

    func remove(_ row: Row) {
        SyntaxStore.shared.remove(row.id)
    }

    func installFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = true
        panel.prompt = "Install"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do {
                try SyntaxStore.shared.install(fileAt: url)
                message = ""
            } catch {
                message = "\(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }
}

private struct SyntaxSettings: View {
    @StateObject private var model = SyntaxListModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Syntaxes are downloaded from GitHub when you install them. Neutrino loads one when a document uses it and unloads it when the last such document closes.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List(model.rows) { row in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.info.name)
                        Text(detail(row)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if model.busy.contains(row.id) {
                        ProgressView().controlSize(.small)
                    } else if let installed = row.installedVersion {
                        if row.published && row.info.version > installed {
                            Button("Update") { model.install(row) }
                        }
                        Button("Remove") { model.remove(row) }
                    } else {
                        Button("Install") { model.install(row) }
                    }
                }
                .controlSize(.small)
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(height: 300)

            if !model.message.isEmpty {
                Text(model.message).font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Refresh List") { model.refresh() }.disabled(model.refreshing)
                if model.refreshing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Install from File…") { model.installFromFile() }
                Button("Show Folder") { SyntaxStore.shared.showFolder() }
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { model.refresh() }
    }

    private func detail(_ row: SyntaxListModel.Row) -> String {
        var parts = row.info.extensions.prefix(8).map { ".\($0)" }
        parts += (row.info.filenames ?? []).prefix(3)
        var text = parts.joined(separator: "  ")
        if !row.published { text = "Added from a file" + (text.isEmpty ? "" : "  ·  " + text) }
        return text
    }
}
