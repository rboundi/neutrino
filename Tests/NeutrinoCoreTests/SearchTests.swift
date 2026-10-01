import XCTest
@testable import NeutrinoCore

final class SearchTests: XCTestCase {
    private func ranges(_ pattern: String, in text: String, _ options: SearchOptions = SearchOptions()) throws -> [NSRange] {
        try SearchQuery(pattern: pattern, options: options).ranges(in: text as NSString)
    }

    func testPlainTextIsLiteral() throws {
        XCTAssertEqual(try ranges("a.b", in: "a.b axb A.B"), [NSRange(location: 0, length: 3), NSRange(location: 8, length: 3)])
        XCTAssertEqual(try ranges("a.b", in: "a.b A.B", SearchOptions(caseSensitive: true)).count, 1)
    }

    func testWholeWord() throws {
        XCTAssertEqual(try ranges("cat", in: "cat concat cats cat.", SearchOptions(wholeWord: true)).count, 2)
    }

    func testRegexAnchorsMatchLines() throws {
        XCTAssertEqual(try ranges("^\\w+$", in: "one\ntwo words\nthree", SearchOptions(regex: true)).count, 2)
    }

    func testInvalidRegexThrows() {
        XCTAssertThrowsError(try SearchQuery(pattern: "(", options: SearchOptions(regex: true)))
        XCTAssertThrowsError(try SearchQuery(pattern: "", options: SearchOptions()))
    }

    func testSearchInRangeSeesContext() throws {
        let text = "foobar bar" as NSString
        let query = try SearchQuery(pattern: "bar", options: SearchOptions(wholeWord: true))
        // "bar" inside "foobar" must not count just because the range starts there.
        XCTAssertEqual(query.ranges(in: text, range: NSRange(location: 3, length: 7)), [NSRange(location: 7, length: 3)])
    }

    func testMatchAtSelection() throws {
        let text = "let x = 10" as NSString
        let query = try SearchQuery(pattern: "\\d+", options: SearchOptions(regex: true))
        XCTAssertNotNil(query.match(at: NSRange(location: 8, length: 2), in: text))
        XCTAssertNil(query.match(at: NSRange(location: 8, length: 1), in: text))
        XCTAssertNil(query.match(at: NSRange(location: 0, length: 3), in: text))
    }

    private func replaced(_ text: String, _ pattern: String, _ template: String, regex: Bool = true) throws -> String {
        let query = try SearchQuery(pattern: pattern, options: SearchOptions(regex: regex, caseSensitive: true))
        let string = text as NSString
        guard let result = query.replaceAll(in: string, with: Replacement(template: template, isRegex: regex)) else { return text }
        return string.replacingCharacters(in: result.range, with: result.text)
    }

    func testCaptureGroups() throws {
        XCTAssertEqual(try replaced("john smith, jane doe", "(\\w+) (\\w+)", "$2 $1"), "smith john, doe jane")
        XCTAssertEqual(try replaced("john smith", "(\\w+) (\\w+)", "\\2-\\1"), "smith-john")
        XCTAssertEqual(try replaced("a=1", "(?<key>\\w)=(?<value>\\d)", "${value}=${key}"), "1=a")
        XCTAssertEqual(try replaced("abc", "b", "[$0][$&]"), "a[b][b]c")
    }

    func testCaseConversion() throws {
        XCTAssertEqual(try replaced("hello world", "(\\w+) (\\w+)", "\\U$1\\E $2"), "HELLO world")
        XCTAssertEqual(try replaced("hello world", "(\\w+)", "\\u$1"), "Hello World")
        XCTAssertEqual(try replaced("HELLO World", "(\\w+)", "\\L$1"), "hello world")
        XCTAssertEqual(try replaced("HELLO", "(\\w+)", "\\l$1"), "hELLO")
        XCTAssertEqual(try replaced("snake_case_name", "_(\\w)", "\\u$1"), "snakeCaseName")
    }

    func testEscapes() throws {
        XCTAssertEqual(try replaced("a,b", ",", "\\n"), "a\nb")
        XCTAssertEqual(try replaced("a,b", ",", "\\t\\$1\\\\"), "a\t$1\\b")
        XCTAssertEqual(try replaced("ab", "(a)", "$1$7x"), "axb")
    }

    func testPlainReplacementIsLiteral() throws {
        XCTAssertEqual(try replaced("a.b", ".", "$1\\n", regex: false), "a$1\\nb")
    }

    func testZeroLengthMatches() throws {
        XCTAssertEqual(try replaced("a\nb", "^", "> "), "> a\n> b")
    }

    func testReplaceAllIsOneEdit() throws {
        let text = "x 1 y 22 z" as NSString
        let query = try SearchQuery(pattern: "\\d+", options: SearchOptions(regex: true))
        let result = try XCTUnwrap(query.replaceAll(in: text, with: Replacement(template: "<$0>", isRegex: true)))
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.range, NSRange(location: 2, length: 6))
        XCTAssertEqual(result.text, "<1> y <22>")
    }
}

extension SearchTests {
    func testDigitsAfterDollarUseTheLongestExistingGroup() throws {
        XCTAssertEqual(try replaced("5", "(\\d)", "$10"), "50")
        let ten = String(repeating: "(\\w)", count: 10)
        XCTAssertEqual(try replaced("abcdefghij", ten, "$10$1"), "ja")
    }

    func testSlowPatternCanBeCancelled() throws {
        let query = try SearchQuery(pattern: "(a+)+$", options: SearchOptions(regex: true))
        let text = String(repeating: "a", count: 40) + "b" as NSString
        let deadline = Date().addingTimeInterval(0.3)
        let start = Date()
        _ = query.ranges(in: text) { Date() > deadline }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
}
