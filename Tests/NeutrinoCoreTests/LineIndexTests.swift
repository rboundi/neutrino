import XCTest
@testable import NeutrinoCore

final class LineIndexTests: XCTestCase {
    func testBuildAndLookup() {
        let index = LineIndex("one\ntwo\n\nfour" as NSString)
        XCTAssertEqual(index.starts, [0, 4, 8, 9])
        XCTAssertEqual(index.line(at: 0), 0)
        XCTAssertEqual(index.line(at: 3), 0)
        XCTAssertEqual(index.line(at: 4), 1)
        XCTAssertEqual(index.line(at: 8), 2)
        XCTAssertEqual(index.line(at: 13), 3)
        XCTAssertEqual(index.start(ofLine: 99), 9)
    }

    /// Random edits must leave the index the same as one built from scratch.
    func testEditsMatchRebuild() {
        var generator = SystemRandomNumberGenerator()
        let text = NSMutableString(string: "alpha\nbeta\n\ngamma\ndelta")
        var index = LineIndex(text)
        let pieces = ["", "x", "\n", "ab\ncd", "\n\n", "long line without a break", "tail\n"]
        for _ in 0..<2000 {
            let location = Int.random(in: 0...text.length, using: &generator)
            let length = Int.random(in: 0...min(6, text.length - location), using: &generator)
            let piece = pieces.randomElement(using: &generator)!
            text.replaceCharacters(in: NSRange(location: location, length: length), with: piece)
            let newLength = (piece as NSString).length
            index.edited(newRange: NSRange(location: location, length: newLength), delta: newLength - length, in: text)
            XCTAssertEqual(index.starts, LineIndex(text).starts)
        }
    }
}
