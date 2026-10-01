import XCTest
@testable import NeutrinoCore

final class IncrementalTests: XCTestCase {
    private static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("syntaxes")

    private func load(_ id: String) throws -> CompiledSyntax {
        try CompiledSyntax(data: Data(contentsOf: Self.folder.appendingPathComponent("\(id).json")))
    }

    private func shift(_ tokens: [Token], location: Int, oldLength: Int, newLength: Int) -> [Token] {
        var tokens = tokens
        CompiledSyntax.shift(
            &tokens, edited: NSRange(location: location, length: newLength), delta: newLength - oldLength)
        return tokens
    }

    /// After any edit, rescanning from the edit must give exactly what a full scan gives.
    /// HTML is left out: its quoted attribute values span lines and need their closing quote to
    /// match, which is the case the editor's full scan on a pause exists for.
    func testRandomEditsMatchAFullScan() throws {
        let samples: [(String, String)] = [
            ("swift", "import Foundation\n\n/* block\n comment */\nfunc run(_ x: Int) -> String {\n    let s = \"a // b\" // note\n    return s + \"\\(x)\"\n}\n\nstruct Point { var x = 0.5 }\n"),
            ("python", "import os\n\ndef f(a, b):\n    '''doc\n    string'''\n    return a + b  # sum\n\nclass K:\n    x = \"s\"\n"),
            ("markdown", "# Title\n\nSome *text* and `code`.\n\n```swift\nlet x = 1\n```\n\n- item\n> quote\n"),
            ("c", "#include <stdio.h>\nint main(void) {\n    /* hi */ printf(\"%d\\n\", 42);\n    return 0;\n}\n"),
        ]
        let pieces = ["", "x", " ", "\n", "\"", "/*", "*/", "//", "'''", "```", "(", "{\n}", "# ", "<!--", "-->", "func ", "0x1F"]
        var generator = SystemRandomNumberGenerator()
        for (id, sample) in samples {
            let syntax = try load(id)
            let text = NSMutableString(string: sample)
            var tokens = syntax.tokenize(text)
            for step in 0..<400 {
                let location = Int.random(in: 0...text.length, using: &generator)
                let length = Int.random(in: 0...min(5, text.length - location), using: &generator)
                let piece = pieces.randomElement(using: &generator)!
                let before = text.copy() as! NSString
                text.replaceCharacters(in: NSRange(location: location, length: length), with: piece)
                let newLength = (piece as NSString).length
                let shifted = shift(tokens, location: location, oldLength: length, newLength: newLength)
                tokens = syntax.retokenize(
                    text, previous: shifted, edited: NSRange(location: location, length: newLength))
                let full = syntax.tokenize(text)
                if tokens != full {
                    XCTFail("\(id) step \(step): replaced \(length) at \(location) with \(piece.debugDescription) in \(before.debugDescription)")
                    tokens = full
                }
            }
        }
    }

    func testAnEditFarFromTheEndReusesTheTail() throws {
        let syntax = try load("swift")
        let text = NSMutableString(string: String(repeating: "let value = 1 // note\n", count: 2000))
        let tokens = syntax.tokenize(text)
        text.insert("x", at: 4)
        let shifted = shift(tokens, location: 4, oldLength: 0, newLength: 1)
        var start = Date()
        let result = syntax.retokenize(text, previous: shifted, edited: NSRange(location: 4, length: 1))
        let incremental = Date().timeIntervalSince(start)
        start = Date()
        let full = syntax.tokenize(text)
        XCTAssertEqual(result, full)
        XCTAssertLessThan(incremental * 5, Date().timeIntervalSince(start), "the scan should stop at the first reused token")
    }

    func testSymbols() throws {
        let swift = "struct Point {\n    func move() {}\n    // MARK: - Drawing\n    private static func draw(_ x: Int) {}\n}\n" as NSString
        XCTAssertEqual(try load("swift").symbols(in: swift).map(\.name), ["Point", "move", "Drawing", "draw"])
        let python = "class A:\n    def run(self):\n        pass\nasync def go():\n    pass\n" as NSString
        XCTAssertEqual(try load("python").symbols(in: python).map(\.name), ["A", "run", "go"])
        let markdown = "# One\ntext\n## Two\n" as NSString
        XCTAssertEqual(try load("markdown").symbols(in: markdown).map(\.name), ["# One", "## Two"])
        let c = "#include <x.h>\nstatic int add(int a, int b) {\n    return a + b;\n}\nint main(void)\n{\n}\nint x = f(1);\n" as NSString
        XCTAssertEqual(try load("c").symbols(in: c).map(\.name), ["add", "main"])
    }
}
