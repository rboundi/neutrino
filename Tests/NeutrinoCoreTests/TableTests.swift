import XCTest
@testable import NeutrinoCore

final class TableTests: XCTestCase {
    func testQuotedFields() {
        let text = "name,note\n\"Smith, J\",\"said \"\"hi\"\"\"\nx,\"two\nlines\"\n\nlast,\n"
        let table = DelimitedTable(text)
        XCTAssertEqual(table.delimiter, ",")
        XCTAssertEqual(table.rows, [["name", "note"], ["Smith, J", "said \"hi\""], ["x", "two\nlines"], ["last", ""]])
        XCTAssertEqual(table.offsets, [0, 10, 35, 50])
        XCTAssertEqual(table.columnCount, 2)
        XCTAssertTrue(table.isComplete)
    }

    func testDelimiters() {
        XCTAssertEqual(DelimitedTable("a;b;c\n1;2,5;3").rows, [["a", "b", "c"], ["1", "2,5", "3"]])
        XCTAssertEqual(DelimitedTable("a\tb\n1\t2").delimiter, "\t")
        XCTAssertEqual(DelimitedTable("a|b|c").rows, [["a", "b", "c"]])
        XCTAssertEqual(DelimitedTable("\"a,b\";c\n").delimiter, ";")
        XCTAssertEqual(DelimitedTable("").rows, [])
    }

    func testRowLimit() {
        let table = DelimitedTable("1\n2\n3\n4\n", maxRows: 2)
        XCTAssertEqual(table.rows, [["1"], ["2"]])
        XCTAssertFalse(table.isComplete)
        XCTAssertTrue(DelimitedTable("1\n2\n", maxRows: 2).isComplete)
    }

    func testFoldBrackets() {
        let text = "{\n  \"a\": [\n    1,\n    2\n  ],\n  \"b\": {}\n}\n" as NSString
        XCTAssertEqual(Folding.range(in: text, lineStart: 0, tabWidth: 2), NSRange(location: 1, length: 38))
        XCTAssertEqual(text.substring(with: Folding.range(in: text, lineStart: 2, tabWidth: 2)!), "\n    1,\n    2\n  ")
        XCTAssertNil(Folding.range(in: text, lineStart: 12, tabWidth: 2))
        XCTAssertTrue(Folding.isFoldable(in: text, lineStart: 0, tabWidth: 2))
        XCTAssertFalse(Folding.isFoldable(in: text, lineStart: 12, tabWidth: 2))
    }

    func testFoldIndentation() {
        let text = "<ul>\n  <li>a</li>\n\n  <li>b</li>\n</ul>\nafter\n" as NSString
        XCTAssertEqual(text.substring(with: Folding.range(in: text, lineStart: 0, tabWidth: 4)!), "\n  <li>a</li>\n\n  <li>b</li>")
        XCTAssertNil(Folding.range(in: text, lineStart: 5, tabWidth: 4))
        XCTAssertTrue(Folding.isFoldable(in: text, lineStart: 0, tabWidth: 4))
        XCTAssertFalse(Folding.isFoldable(in: text, lineStart: 32, tabWidth: 4))
        XCTAssertNil(Folding.range(in: "one\n" as NSString, lineStart: 0, tabWidth: 4))
    }
}
