import XCTest
@testable import NeutrinoCore

final class EditorConfigTests: XCTestCase {
    func testGlobs() {
        XCTAssertTrue(EditorConfig.matches(pattern: "*", path: "a/b/c.py"))
        XCTAssertTrue(EditorConfig.matches(pattern: "*.py", path: "a/b/c.py"))
        XCTAssertFalse(EditorConfig.matches(pattern: "*.py", path: "c.pyc"))
        XCTAssertTrue(EditorConfig.matches(pattern: "*.{js,ts}", path: "src/app.ts"))
        XCTAssertFalse(EditorConfig.matches(pattern: "*.{js,ts}", path: "src/app.tsx"))
        XCTAssertTrue(EditorConfig.matches(pattern: "Makefile", path: "sub/Makefile"))
        XCTAssertTrue(EditorConfig.matches(pattern: "lib/**.js", path: "lib/a/b.js"))
        XCTAssertFalse(EditorConfig.matches(pattern: "lib/*.js", path: "lib/a/b.js"))
        XCTAssertFalse(EditorConfig.matches(pattern: "lib/*.js", path: "src/lib/b.js"))
        XCTAssertTrue(EditorConfig.matches(pattern: "/docs/*.md", path: "docs/a.md"))
        XCTAssertTrue(EditorConfig.matches(pattern: "file[0-9].txt", path: "file7.txt"))
        XCTAssertTrue(EditorConfig.matches(pattern: "file[!0-9].txt", path: "fileA.txt"))
        XCTAssertTrue(EditorConfig.matches(pattern: "v{1..3}.txt", path: "v2.txt"))
        XCTAssertFalse(EditorConfig.matches(pattern: "v{1..3}.txt", path: "v4.txt"))
        XCTAssertTrue(EditorConfig.matches(pattern: "a?c", path: "abc"))
    }

    func testNearerFilesAndLaterSectionsWin() {
        let files = [
            "/repo/.editorconfig": "root = true\n[*]\nindent_style = space\nindent_size = 4\ninsert_final_newline = true\n[*.go]\nindent_style = tab\n",
            "/repo/web/.editorconfig": "[*.js]\nindent_size = 2\ntrim_trailing_whitespace = true\n",
            "/.editorconfig": "[*]\nindent_size = 8\n",
        ]
        let read: (URL) -> String? = { files[$0.path] }

        let js = EditorConfig.load(for: URL(fileURLWithPath: "/repo/web/src/app.js"), read: read)
        XCTAssertEqual(js.indentWithSpaces, true)
        XCTAssertEqual(js.indentWidth, 2)
        XCTAssertEqual(js.trimTrailingWhitespace, true)
        XCTAssertEqual(js.insertFinalNewline, true)

        let go = EditorConfig.load(for: URL(fileURLWithPath: "/repo/main.go"), read: read)
        XCTAssertEqual(go.indentWithSpaces, false)
        XCTAssertEqual(go.indentWidth, 4, "the file above root = true must not be read")

        XCTAssertTrue(EditorConfig.load(for: URL(fileURLWithPath: "/tmp/x.txt"), read: { _ in nil }).isEmpty)
    }

    func testTabWidthStandsInForIndentSize() {
        let read: (URL) -> String? = { $0.path == "/p/.editorconfig" ? "[*]\nindent_size = tab\ntab_width = 3\n" : nil }
        XCTAssertEqual(EditorConfig.load(for: URL(fileURLWithPath: "/p/a.c"), read: read).indentWidth, 3)
    }
}

final class UnifiedDiffTests: XCTestCase {
    func testEqualTextsHaveNoDiff() {
        XCTAssertNil(UnifiedDiff.make(old: "a\nb\n", new: "a\nb\n", oldName: "x", newName: "y"))
    }

    func testOneChangedLine() {
        let old = (1...10).map { "line \($0)" }.joined(separator: "\n")
        let new = old.replacingOccurrences(of: "line 5", with: "LINE 5")
        XCTAssertEqual(
            UnifiedDiff.make(old: old, new: new, oldName: "saved", newName: "now"),
            "--- saved\n+++ now\n@@ -2,7 +2,7 @@\n line 2\n line 3\n line 4\n-line 5\n+LINE 5\n line 6\n line 7\n line 8\n")
    }

    func testDistantChangesMakeSeparateHunks() throws {
        let old = (1...40).map { "line \($0)" }.joined(separator: "\n")
        var lines = old.components(separatedBy: "\n")
        lines.remove(at: 2)
        lines.insert("added", at: 30)
        let diff = try XCTUnwrap(UnifiedDiff.make(old: old, new: lines.joined(separator: "\n"), oldName: "a", newName: "b"))
        XCTAssertEqual(diff.components(separatedBy: "\n@@ ").count - 1, 2)
        XCTAssertTrue(diff.contains("\n-line 3\n"))
        XCTAssertTrue(diff.contains("\n+added\n"))
    }
}

final class ThemeDefinitionTests: XCTestCase {
    func testColours() {
        XCTAssertEqual(ThemeDefinition.rgb("#FF0080")?.red, 1)
        XCTAssertEqual(ThemeDefinition.rgb("#FF0080")?.green, 0)
        XCTAssertNil(ThemeDefinition.rgb("red"))
        XCTAssertNil(ThemeDefinition.rgb("#FFF"))
    }
}

extension ThemeDefinitionTests {
    private static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("themes")

    func testEveryPublishedThemeIsValidAndListed() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "index.json" }
        XCTAssertFalse(files.isEmpty)
        var infos: [ThemeInfo] = []
        for file in files {
            let theme = try JSONDecoder().decode(ThemeDefinition.self, from: Data(contentsOf: file))
            XCTAssertNoThrow(try theme.validate(), file.lastPathComponent)
            XCTAssertEqual(theme.id, file.deletingPathExtension().lastPathComponent)
            for scope in theme.scopes.keys {
                XCTAssertNotNil(Scope(rawValue: scope), "\(file.lastPathComponent): unknown scope \(scope)")
            }
            infos.append(theme.info)
        }
        let catalog = try JSONDecoder().decode(
            ThemeCatalog.self, from: Data(contentsOf: Self.folder.appendingPathComponent("index.json")))
        XCTAssertEqual(
            catalog.themes.sorted { $0.id < $1.id }, infos.sorted { $0.id < $1.id }, "run scripts/make_index.py")
    }
}
