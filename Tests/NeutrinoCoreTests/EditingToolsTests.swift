import XCTest
@testable import NeutrinoCore

final class EditingToolsTests: XCTestCase {
    private func hashes(_ text: String) -> [Int] { LineHashes.make(text as NSString) }

    func testLineHashes() {
        XCTAssertEqual(hashes("a\nb\n").count, 3)
        XCTAssertEqual(hashes("").count, 1)
        XCTAssertEqual(hashes("a\nb")[0], hashes("a")[0])
        XCTAssertNotEqual(hashes("a")[0], hashes("b")[0])
    }

    func testChangedLines() {
        let old = hashes("one\ntwo\nthree\nfour\nfive")
        XCTAssertTrue(ChangedLines.compare(old: old, new: old).isEmpty)

        var result = ChangedLines.compare(old: old, new: hashes("one\nTWO\nthree\nfour\nfive"))
        XCTAssertEqual(result.changed, [1])
        XCTAssertEqual(result.removed, [])

        result = ChangedLines.compare(old: old, new: hashes("one\ntwo\nnew\nthree\nfour\nfive"))
        XCTAssertEqual(result.changed, [2])

        result = ChangedLines.compare(old: old, new: hashes("one\nthree\nfour\nfive"))
        XCTAssertEqual(result.changed, [])
        XCTAssertEqual(result.removed, [1])

        // Two edits far apart, with unchanged lines between them.
        result = ChangedLines.compare(old: old, new: hashes("ONE\ntwo\nthree\nfive\nsix"))
        XCTAssertEqual(result.changed, [0, 4])
        XCTAssertEqual(result.removed, [3])

        // The last line removed: the mark goes on the line that is now last.
        result = ChangedLines.compare(old: old, new: hashes("one\ntwo\nthree\nfour"))
        XCTAssertEqual(result.removed, [3])

        // Too many differences: everything between the first and the last counts.
        result = ChangedLines.compare(old: hashes("a\nb\nc\nd\ne"), new: hashes("a\nx\nc\ny\ne"), maxEdits: 1)
        XCTAssertEqual(result.changed, [1, 2, 3])
    }

    func testEditScriptIsConsistent() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let a = (0..<Int.random(in: 0...30, using: &generator)).map { _ in Int.random(in: 0...4, using: &generator) }
            let b = (0..<Int.random(in: 0...30, using: &generator)).map { _ in Int.random(in: 0...4, using: &generator) }
            guard let script = ChangedLines.edits(a, b, limit: 100) else { return XCTFail("no script") }
            // What is left of `b` without the insertions is what is left of `a` without the removals.
            XCTAssertEqual(b.count - script.inserted.count, a.count - script.removedAt.count)
            let kept = b.enumerated().filter { !script.inserted.contains($0.offset) }.map(\.element)
            var position = 0
            for value in kept {
                guard let found = a[position...].firstIndex(of: value) else { return XCTFail("not a subsequence") }
                position = found + 1
            }
        }
    }

    func testJSONPath() {
        let text = "{\"items\": [{\"name\": \"a\"}, {\"name\": \"b\", \"my key\": [1, 2, 3]}], \"n\": 1}" as NSString
        func path(after marker: String) -> String? {
            JSONPath.path(in: text, at: NSMaxRange(text.range(of: marker)))
        }
        XCTAssertNil(JSONPath.path(in: text, at: 0))
        XCTAssertEqual(path(after: "\"items\": "), "items")
        XCTAssertEqual(path(after: "\"name\": \"a"), "items[0].name")
        XCTAssertEqual(path(after: "\"b"), "items[1].name")
        XCTAssertEqual(path(after: "[1, 2"), "items[1][\"my key\"][1]")
        XCTAssertEqual(path(after: "\"n\": "), "n")
        // Inside a key, the whole key is read.
        XCTAssertEqual(path(after: "\"ite"), "items")
        XCTAssertNil(JSONPath.path(in: text, at: text.length))
        XCTAssertNil(JSONPath.path(in: text, at: 20, limit: 10))
    }

    func testSnippets() {
        let file = "Explanation\n\n=== for\nfor x in y {\n\t$0\n}\n\n=== log debug\nprint()\n=== empty\n"
        let snippets = Snippets.parse(file)
        XCTAssertEqual(snippets, ["for": "for x in y {\n\t$0\n}", "log": "print()"])
        let expanded = Snippets.expand(snippets["for"]!, indent: "  ", unit: "    ")
        XCTAssertEqual(expanded.text, "for x in y {\n      \n  }")
        XCTAssertEqual(expanded.caret, 19)
        XCTAssertEqual(Snippets.expand("abc", indent: "", unit: "\t").caret, 3)
    }

    func testCalculator() {
        XCTAssertEqual(Calculator.evaluate("1024*8+12"), 8204)
        XCTAssertEqual(Calculator.evaluate(" (1 + 2) * -3 "), -9)
        XCTAssertEqual(Calculator.evaluate("2^3^2"), 512)
        XCTAssertEqual(Calculator.evaluate("-2^2"), -4)
        XCTAssertEqual(Calculator.evaluate("10 % 4 + 0x10 + 0b11"), 21)
        XCTAssertEqual(Calculator.evaluate("sqrt(16) + 1e3 + 1_000"), 2004)
        XCTAssertEqual(Calculator.evaluate("7 ÷ 2 × 2"), 7)
        XCTAssertNil(Calculator.evaluate("1/0"))
        XCTAssertNil(Calculator.evaluate("1 +"))
        XCTAssertNil(Calculator.evaluate("hello"))
        XCTAssertNil(Calculator.evaluate(""))
        XCTAssertNil(Calculator.evaluate(String(repeating: "(", count: 5000)))
        XCTAssertEqual(Calculator.format(8204), "8204")
        XCTAssertEqual(Calculator.format(0.1 + 0.2), "0.3")
        XCTAssertEqual(Calculator.format(-2.5), "-2.5")
    }

    func testNumbers() {
        let found = TextStats.numbers(in: "a 10, -2.5 and 4\nx86 v1.2.3 7px")
        XCTAssertEqual(found?.count, 3)
        XCTAssertEqual(found?.sum, 11.5)
        XCTAssertEqual(found?.min, -2.5)
        XCTAssertEqual(found?.max, 10)
        XCTAssertNil(TextStats.numbers(in: "none"))
    }

    func testTableExports() {
        let titles = ["name", "n"]
        let rows = [["a|b", "1"], ["two\nlines"], ["q\"", "01"]]
        XCTAssertEqual(
            DelimitedTable.markdown(titles: titles, rows: rows),
            "| name | n |\n| --- | --- |\n| a\\|b | 1 |\n| two lines |  |\n| q\" | 01 |\n")
        XCTAssertEqual(
            DelimitedTable.json(titles: titles, rows: rows),
            "[\n  {\"name\": \"a|b\", \"n\": 1},\n  {\"name\": \"two\\nlines\", \"n\": \"\"},\n  {\"name\": \"q\\\"\", \"n\": \"01\"}\n]\n")
        XCTAssertEqual(DelimitedTable.tabSeparated([["a\tb", "c"], ["d"]]), "a b\tc\nd\n")
    }

    func testFoldLevels() {
        let text = "a {\n  b {\n    c\n  } else {\n    d\n  }\n}\nlist:\n  - x\n  - y\nend\n" as NSString
        func folded(_ level: Int) -> [String] {
            Folding.ranges(in: text, level: level, tabWidth: 4).map { text.substring(with: $0) }
        }
        XCTAssertEqual(folded(1), ["\n  b {\n    c\n  } else {\n    d\n  }\n", "\n  - x\n  - y"])
        XCTAssertEqual(folded(2), ["\n    c\n  ", "\n    d\n  "])
        XCTAssertEqual(folded(3), [])
    }
}

final class ReviewFixTests: XCTestCase {
    func testReplacementWithOddDigitsDoesNotCrash() throws {
        let query = try SearchQuery(pattern: "(a)", options: SearchOptions(regex: true))
        let text = "a" as NSString
        XCTAssertEqual(query.replaceAll(in: text, with: Replacement(template: "\\5\u{FE0F}\u{20E3}", isRegex: true))?.text, "5\u{FE0F}\u{20E3}")
        XCTAssertEqual(query.replaceAll(in: text, with: Replacement(template: "[\\1]", isRegex: true))?.text, "[a]")
    }

    func testMatchAtUsesContextAroundTheSelection() throws {
        let text = NSMutableString(string: String(repeating: "x", count: 30_000) + "foo bar" + String(repeating: "y", count: 30_000))
        let query = try SearchQuery(pattern: "(?<=o )(b)ar(?=y)", options: SearchOptions(regex: true))
        let match = query.match(at: NSRange(location: 30_004, length: 3), in: text)
        XCTAssertEqual(match?.range, NSRange(location: 30_004, length: 3))
        XCTAssertEqual(match?.range(at: 1), NSRange(location: 30_004, length: 1))
        XCTAssertNil(query.match(at: NSRange(location: 30_000, length: 3), in: text))
    }

    func testReplaceAllStreamsAndCancels() throws {
        let query = try SearchQuery(pattern: "\\d+", options: SearchOptions(regex: true))
        let result = query.replaceAll(in: "a 1 b 22 c", with: Replacement(template: "<$0>", isRegex: true))
        XCTAssertEqual(result?.text, "<1> b <22>")
        XCTAssertEqual(result?.range, NSRange(location: 2, length: 6))
        XCTAssertEqual(result?.count, 2)
        XCTAssertNil(query.replaceAll(in: "none", with: Replacement(template: "", isRegex: true)))
        let long = String(repeating: "1 ", count: 5000) as NSString
        XCTAssertNil(query.replaceAll(in: long, with: Replacement(template: "", isRegex: true), isCancelled: { true }))
    }

    func testBackreferencesSurviveJoiningRules() throws {
        XCTAssertEqual(CompiledSyntax.renumbered("([\"'])x\\1 \\\\1 \\d \\0", by: 3), "([\"'])x\\4 \\\\1 \\d \\0")
        let definition = SyntaxDefinition(
            id: "t", name: "T", version: 1, extensions: [], rules: [
                SyntaxRule(scope: "keyword", words: ["let"]),
                SyntaxRule(scope: "string", match: "([\"'])[^\"']*\\1"),
            ])
        let tokens = try CompiledSyntax(definition).tokenize("let a = 'x' + \"y'" as NSString)
        XCTAssertEqual(tokens.map(\.scope), [.keyword, .string])
        XCTAssertEqual(tokens.last?.range, NSRange(location: 8, length: 3))
    }

    func testEditInOneLongLineRestartsNearby() throws {
        let definition = SyntaxDefinition(
            id: "t", name: "T", version: 1, extensions: [], rules: [SyntaxRule(scope: "number", match: "\\d+")])
        let syntax = try CompiledSyntax(definition)
        let text = NSMutableString(string: String(repeating: "ab 12 ", count: 10_000))
        var tokens = syntax.tokenize(text)
        text.insert("7", at: 50_000)
        let edited = NSRange(location: 50_000, length: 1)
        CompiledSyntax.shift(&tokens, edited: edited, delta: 1)
        XCTAssertEqual(syntax.retokenize(text, previous: tokens, edited: edited), syntax.tokenize(text))
    }

    func testIDs() {
        XCTAssertTrue(SyntaxInfo.isValidID("c#"))
        XCTAssertFalse(SyntaxInfo.isValidID("abc\n"))
    }

    func testRememberedFoldsMustFit() {
        let text = "a {\n  b\n}\nlist:\n  - x\nend" as NSString
        XCTAssertTrue(Folding.fits(NSRange(location: 3, length: 5), in: text))
        XCTAssertTrue(Folding.fits(NSRange(location: 15, length: 6), in: text))
        XCTAssertFalse(Folding.fits(NSRange(location: 4, length: 5), in: text))
        XCTAssertFalse(Folding.fits(NSRange(location: 3, length: 500), in: text))
        XCTAssertFalse(Folding.fits(NSRange(location: 0, length: 3), in: text))
    }
}
