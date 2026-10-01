import AppKit
import NeutrinoCore
import SwiftUI

/// The Settings window: one short page per toolbar tab.
final class SettingsWindowController: NSWindowController {
    enum Tab: Int {
        case general, editor, appearance, syntaxes
    }

    static let shared = SettingsWindowController()

    private let tabs = NSTabViewController()

    private init() {
        tabs.tabStyle = .toolbar
        let pages: [(String, String, AnyView)] = [
            ("General", "gearshape", AnyView(GeneralSettings())),
            ("Editor", "text.cursor", AnyView(EditorSettings())),
            ("Appearance", "paintpalette", AnyView(AppearanceSettings())),
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
    @AppStorage(Prefs.keepWindows) private var keepWindows = true
    @AppStorage(Prefs.autosave) private var autosave = true
    @AppStorage(Prefs.checkForUpdates) private var checkForUpdates = true

    var body: some View {
        Page {
            Section {
                Toggle("Save changes automatically", isOn: $autosave)
                Toggle("Keep windows and unsaved text when quitting", isOn: $keepWindows)
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
    @AppStorage(Prefs.detectIndentation) private var detectIndentation = true
    @AppStorage(Prefs.pageGuide) private var pageGuide = 0
    @AppStorage(Prefs.checkSpelling) private var checkSpelling = false
    @AppStorage(Prefs.indentGuides) private var indentGuides = false
    @AppStorage(Prefs.markTrailingSpaces) private var markTrailingSpaces = false
    @AppStorage(Prefs.showColours) private var showColours = false
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
                Toggle("Use the indentation a file already has", isOn: $detectIndentation)
                Toggle("Keep the indentation on new lines", isOn: $autoIndent)
                Toggle("Close brackets and quotes", isOn: $autoCloseBrackets)
            }
            Section("Display") {
                Toggle("Wrap lines", isOn: $wrapLines)
                Toggle("Line numbers", isOn: $lineNumbers)
                Toggle("Highlight the current line", isOn: $highlightCurrentLine)
                Toggle("Show invisible characters", isOn: $showInvisibles)
                Picker("Page guide", selection: $pageGuide) {
                    Text("None").tag(0)
                    ForEach([72, 80, 100, 120], id: \.self) { Text("After column \($0)").tag($0) }
                }
                Toggle("Indent guides", isOn: $indentGuides)
                Toggle("Mark spaces at the end of lines", isOn: $markTrailingSpaces)
                Toggle("Underline hex colours in their colour", isOn: $showColours)
                Toggle("Check spelling while typing", isOn: $checkSpelling)
            }
            Section("When saving") {
                Toggle("Remove trailing spaces", isOn: $trimTrailingWhitespace)
                Toggle("End the file with a line break", isOn: $ensureFinalNewline)
            }
        }
    }
}

/// One line of a list of installable files: a syntax or a theme.
private struct PackageRow: Identifiable {
    var id: String
    var name: String
    var detail: String
    var version: Int
    var installedVersion: Int?
    var published: Bool
}

/// A list of installable files shown in Settings, kept in step with its `PackageFolder`.
private final class PackageListModel<Info: Codable & Identifiable>: ObservableObject where Info.ID == String {
    @Published var rows: [PackageRow] = []
    @Published var busy: Set<String> = []
    @Published var message = ""
    @Published var refreshing = false

    private let folder: PackageFolder<Info>
    private let row: (Info) -> PackageRow
    private var observer: NSObjectProtocol?

    init(_ folder: PackageFolder<Info>, row: @escaping (Info) -> PackageRow) {
        self.folder = folder
        self.row = row
        reload()
        observer = NotificationCenter.default.addObserver(
            forName: folder.didChange, object: nil, queue: .main
        ) { [weak self] _ in self?.reload() }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func reload() {
        let installed = Dictionary(uniqueKeysWithValues: folder.installed.map { ($0.id, row($0)) })
        var rows = folder.catalog.map { info -> PackageRow in
            var entry = row(info)
            entry.installedVersion = installed[info.id]?.version
            return entry
        }
        let published = Set(rows.map(\.id))
        // Files added by hand that the repository doesn't have.
        rows += installed.values.filter { !published.contains($0.id) }.map { entry in
            var entry = entry
            entry.installedVersion = entry.version
            entry.published = false
            return entry
        }
        self.rows = rows.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func refresh() {
        refreshing = true
        folder.refreshCatalog { [weak self] error in
            self?.refreshing = false
            self?.message = error.map { "Couldn't load the list: \($0.localizedDescription)" } ?? ""
        }
    }

    func install(_ row: PackageRow) {
        busy.insert(row.id)
        folder.install(id: row.id) { [weak self] error in
            self?.busy.remove(row.id)
            self?.message = error.map { "Couldn't install \(row.name): \($0.localizedDescription)" } ?? ""
        }
    }

    func remove(_ row: PackageRow) {
        folder.remove(row.id)
    }

    func installFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = true
        panel.prompt = "Install"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do {
                try folder.install(fileAt: url)
                message = ""
            } catch {
                message = "\(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    func showFolder() {
        folder.showFolder()
    }
}

private struct PackageList<Info: Codable & Identifiable>: View where Info.ID == String {
    @ObservedObject var model: PackageListModel<Info>
    var height: CGFloat

    var body: some View {
        List(model.rows) { row in
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name)
                    Text(row.published ? row.detail : "Added from a file" + (row.detail.isEmpty ? "" : "  ·  " + row.detail))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if model.busy.contains(row.id) {
                    ProgressView().controlSize(.small)
                } else if let installed = row.installedVersion {
                    if row.published && row.version > installed {
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
        .frame(height: height)

        if !model.message.isEmpty {
            Text(model.message).font(.callout).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack {
            Button("Refresh List") { model.refresh() }.disabled(model.refreshing)
            if model.refreshing { ProgressView().controlSize(.small) }
            Spacer()
            Button("Install from File…") { model.installFromFile() }
            Button("Show Folder") { model.showFolder() }
        }
    }
}

private struct SyntaxSettings: View {
    @StateObject private var model = PackageListModel(SyntaxStore.shared.files) { info in
        let parts = info.extensions.prefix(8).map { ".\($0)" } + (info.filenames ?? []).prefix(3)
        return PackageRow(
            id: info.id, name: info.name, detail: parts.joined(separator: "  "), version: info.version,
            published: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Syntaxes are downloaded from GitHub when you install them. Neutrino loads one when a document uses it and unloads it when the last such document closes.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            PackageList(model: model, height: 300)
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { model.refresh() }
    }
}

private struct AppearanceSettings: View {
    @AppStorage(Prefs.appearance) private var appearance = AppearanceMode.system.rawValue
    @AppStorage(Prefs.theme) private var theme = ""
    @StateObject private var model = PackageListModel(ThemeStore.shared.files) { info in
        PackageRow(
            id: info.id, name: info.name, detail: info.dark ? "Dark" : "Light", version: info.version,
            published: true)
    }

    private var installed: [PackageRow] {
        model.rows.filter { $0.installedVersion != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Colours", selection: $theme) {
                Text("Built in").tag("")
                ForEach(installed) { Text($0.name).tag($0.id) }
            }
            Picker("Appearance", selection: $appearance) {
                ForEach(AppearanceMode.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .disabled(!theme.isEmpty)

            Text("Themes are downloaded from GitHub when you install them. A theme sets the appearance itself.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            PackageList(model: model, height: 220)
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { model.refresh() }
        .onChange(of: installed.map(\.id)) { ids in
            // The theme in use was removed.
            if !theme.isEmpty && !ids.contains(theme) { theme = "" }
        }
    }
}
