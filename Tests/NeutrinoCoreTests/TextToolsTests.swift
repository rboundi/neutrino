import XCTest
@testable import NeutrinoCore

final class TextToolsTests: XCTestCase {
    func testDetectsSpacesAndWidth() {
        let two = "a:\n  b:\n    c: 1\n  d: 2\ne:\n  f: 3\n" as NSString
        XCTAssertEqual(Indentation.detect(in: two)?.indentWithSpaces, true)
        XCTAssertEqual(Indentation.detect(in: two)?.indentWidth, 2)
        let four = "func a() {\n    if x {\n        y()\n    }\n}\n" as NSString
        XCTAssertEqual(Indentation.detect(in: four)?.indentWidth, 4)
    }

    func testDetectsTabs() {
        let text = "all:\n\tcc a.c\n\tcc b.c\nclean:\n\trm a\n" as NSString
        let found = Indentation.detect(in: text)
        XCTAssertEqual(found?.indentWithSpaces, false)
        XCTAssertNil(found?.indentWidth)
    }

    func testTooLittleIndentationIsNotAGuess() {
        XCTAssertNil(Indentation.detect(in: "one\ntwo\n  three\n"))
        XCTAssertNil(Indentation.detect(in: ""))
    }

    func testCommentContinuationDoesNotCountAsAStep() {
        let text = "/*\n * a\n * b\n */\nfunc a() {\n    b()\n    c()\n}\n" as NSString
        XCTAssertEqual(Indentation.detect(in: text)?.indentWidth, 4)
    }

    func testConvertIndentation() {
        XCTAssertEqual(Indentation.convert("\ta\n\t\tb c\n  \td", toSpaces: true, width: 4), "    a\n        b c\n    d")
        XCTAssertEqual(Indentation.convert("    a\n      b  c\nd", toSpaces: false, width: 4), "\ta\n\t  b  c\nd")
    }

    func testWords() {
        let text = "  one two\tthree\nfour  " as NSString
        XCTAssertEqual(TextStats.words(in: text, range: NSRange(location: 0, length: text.length)), 4)
        XCTAssertEqual(TextStats.words(in: text, range: NSRange(location: 2, length: 5)), 2)
        XCTAssertEqual(TextStats.words(in: text, range: NSRange(location: 0, length: 0)), 0)
    }

    func testJSONKeepsOrderAndNumbers() {
        let source = #"{"b":1.50,"a":[1,2,{"x":"a,b:{}"}],"e":{},"n":null}"#
        let pretty = TextTransform.json(source, indent: "  ")
        XCTAssertEqual(pretty, """
            {
              "b": 1.50,
              "a": [
                1,
                2,
                {
                  "x": "a,b:{}"
                }
              ],
              "e": {},
              "n": null
            }
            """)
        XCTAssertEqual(TextTransform.json(pretty!, indent: nil), source)
        XCTAssertEqual(TextTransform.json(#"{"s":"q\"}"}"#, indent: nil), #"{"s":"q\"}"}"#)
        XCTAssertNil(TextTransform.json("{not json}", indent: "  "))
    }

    func testBase64AndURL() {
        XCTAssertEqual(TextTransform.base64Encode("héllo"), "aMOpbGxv")
        XCTAssertEqual(TextTransform.base64Decode("aMOp\nbGxv "), "héllo")
        XCTAssertNil(TextTransform.base64Decode("not base64!"))
        XCTAssertEqual(TextTransform.urlEncode("a b&c=d/é"), "a%20b%26c%3Dd%2F%C3%A9")
        XCTAssertEqual(TextTransform.urlDecode("a%20b%26c"), "a b&c")
    }
}
