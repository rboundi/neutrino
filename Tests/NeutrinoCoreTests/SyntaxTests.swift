import XCTest
@testable import NeutrinoCore

final class SyntaxTests: XCTestCase {
    private static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("syntaxes")

    private func files() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "index.json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func load(_ id: String) throws -> CompiledSyntax {
        try CompiledSyntax(data: Data(contentsOf: Self.folder.appendingPathComponent("\(id).json")))
    }

    /// Scope names of the tokens, with the text they cover.
    private func tokens(_ id: String, _ text: String) throws -> [String] {
        let string = text as NSString
        return try load(id).tokenize(string).map { "\($0.scope.rawValue):\(string.substring(with: $0.range))" }
    }

    func testEveryPublishedSyntaxCompiles() throws {
        let files = try files()
        XCTAssertFalse(files.isEmpty)
        for file in files {
            do {
                let syntax = try CompiledSyntax(data: Data(contentsOf: file))
                XCTAssertEqual(syntax.definition.id, file.deletingPathExtension().lastPathComponent)
                XCTAssertFalse(syntax.definition.rules.isEmpty)
                for rule in syntax.definition.rules {
                    XCTAssertNotNil(Scope(rawValue: rule.scope), "\(file.lastPathComponent): unknown scope \(rule.scope)")
                }
                // Must cope with text it wasn't written for.
                _ = syntax.tokenize("\"unterminated /* 'x' `\n<a b=\"c\"> # -- */ 0x1F\n" as NSString)
            } catch {
                XCTFail("\(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    func testIndexMatchesTheFiles() throws {
        let catalog = try JSONDecoder().decode(
            SyntaxCatalog.self, from: Data(contentsOf: Self.folder.appendingPathComponent("index.json")))
        let infos = try files().map { try JSONDecoder().decode(SyntaxInfo.self, from: Data(contentsOf: $0)) }
        XCTAssertEqual(
            catalog.syntaxes.sorted { $0.id < $1.id }, infos.sorted { $0.id < $1.id },
            "run scripts/make_index.py")
        let extensions = infos.flatMap(\.extensions)
        XCTAssertEqual(extensions.count, Set(extensions).count, "an extension is claimed by two syntaxes")
    }

    func testSwift() throws {
        XCTAssertEqual(
            try tokens("swift", "let x = foo(\"a // b\") // done\n/* multi\nline */ nil 42"),
            ["keyword:let", "function:foo", "string:\"a // b\"", "comment:// done", "comment:/* multi\nline */",
             "constant:nil", "number:42"])
    }

    func testStringsStopAtEndOfLine() throws {
        XCTAssertEqual(try tokens("javascript", "x = \"open\nreturn 1"), ["string:\"open", "keyword:return", "number:1"])
        XCTAssertEqual(try tokens("javascript", #""a\"b" c"#), [#"string:"a\"b""#])
    }

    func testUnterminatedBlockCommentRunsToTheEnd() throws {
        XCTAssertEqual(try tokens("c", "int a; /* never closed\nint b;"), ["type:int", "comment:/* never closed\nint b;"])
    }

    func testPython() throws {
        XCTAssertEqual(
            try tokens("python", "def run(self):\n    return f\"{x}\" # go\n'''doc\nstring'''"),
            ["keyword:def", "function:run", "constant:self", "keyword:return", "string:f\"{x}\"", "comment:# go",
             "string:'''doc\nstring'''"])
    }

    func testMarkup() throws {
        XCTAssertEqual(
            try tokens("html", "<a href=\"x\">don't</a><!-- c -->"),
            ["tag:<a", "attribute:href", "string:\"x\"", "tag:>", "tag:</a", "tag:>", "comment:<!-- c -->"])
    }

    func testSQLIgnoresCase() throws {
        XCTAssertEqual(try tokens("sql", "SELECT a from t -- x"), ["keyword:SELECT", "keyword:from", "comment:-- x"])
    }

    func testMarkdownFence() throws {
        XCTAssertEqual(
            try tokens("markdown", "# Title\n```swift\nlet # x\n```\n**bold**"),
            ["heading:# Title", "string:```swift\nlet # x\n```", "emphasis:**bold**"])
    }

    func testRustRawStringAndLifetime() throws {
        XCTAssertEqual(
            try tokens("rust", "r#\"a \" b\"# &'a 'x'"),
            ["string:r#\"a \" b\"#", "attribute:'a", "string:'x'"])
    }

    func testCatalogMatching() {
        let list = [
            SyntaxInfo(id: "ruby", name: "Ruby", version: 1, extensions: ["rb"], filenames: ["Gemfile"],
                       firstLine: "^#!.*\\bruby"),
            SyntaxInfo(id: "python", name: "Python", version: 1, extensions: ["py"]),
        ]
        XCTAssertEqual(SyntaxCatalog.match(list, filename: "a.PY", firstLine: "")?.id, "python")
        XCTAssertEqual(SyntaxCatalog.match(list, filename: "Gemfile", firstLine: "")?.id, "ruby")
        XCTAssertEqual(SyntaxCatalog.match(list, filename: "script", firstLine: "#!/usr/bin/env ruby")?.id, "ruby")
        XCTAssertNil(SyntaxCatalog.match(list, filename: "notes.txt", firstLine: "hello"))
    }

    func testBadSyntaxFilesAreRejected() {
        XCTAssertThrowsError(try CompiledSyntax(data: Data("{}".utf8)))
        let badRule = #"{"id":"x","name":"X","version":1,"extensions":[],"rules":[{"scope":"comment","match":"("}]}"#
        XCTAssertThrowsError(try CompiledSyntax(data: Data(badRule.utf8)))
        let badID = #"{"id":"../x","name":"X","version":1,"extensions":[],"rules":[]}"#
        XCTAssertThrowsError(try CompiledSyntax(data: Data(badID.utf8)))
    }
}
