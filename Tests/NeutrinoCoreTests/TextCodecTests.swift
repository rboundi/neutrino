import XCTest
@testable import NeutrinoCore

final class TextCodecTests: XCTestCase {
    func testBinaryDetection() {
        XCTAssertTrue(TextCodec.looksBinary(Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01])))
        XCTAssertFalse(TextCodec.looksBinary(Data("plain text".utf8)))
        XCTAssertFalse(TextCodec.looksBinary(Data([0xFF, 0xFE, 0x61, 0x00])))
        XCTAssertFalse(TextCodec.looksBinary(Data()))
    }

    func testUTF8RoundTrip() throws {
        let decoded = try XCTUnwrap(TextCodec.decode(Data("héllo\nwörld\n".utf8)))
        XCTAssertEqual(decoded.encoding, .utf8)
        XCTAssertFalse(decoded.hasBOM)
        XCTAssertEqual(decoded.lineEnding, .lf)
        let data = TextCodec.encode(decoded.text, encoding: .utf8, hasBOM: false, lineEnding: .lf)
        XCTAssertEqual(data, Data("héllo\nwörld\n".utf8))
    }

    func testBOMAndCRLFAreKept() throws {
        let original = Data([0xEF, 0xBB, 0xBF]) + Data("a\r\nb\r\n".utf8)
        let decoded = try XCTUnwrap(TextCodec.decode(original))
        XCTAssertTrue(decoded.hasBOM)
        XCTAssertEqual(decoded.lineEnding, .crlf)
        XCTAssertEqual(decoded.text, "a\nb\n")
        let data = TextCodec.encode(decoded.text, encoding: decoded.encoding, hasBOM: true, lineEnding: .crlf)
        XCTAssertEqual(data, original)
    }

    func testUTF16WithBOM() throws {
        let original = try XCTUnwrap("grüße\n".data(using: .utf16))
        let decoded = try XCTUnwrap(TextCodec.decode(original))
        XCTAssertEqual(decoded.encoding, .utf16)
        XCTAssertEqual(decoded.text, "grüße\n")
    }

    func testInvalidUTF8FallsBack() throws {
        let latin1 = try XCTUnwrap("café".data(using: .isoLatin1))
        let decoded = try XCTUnwrap(TextCodec.decode(latin1))
        XCTAssertNotEqual(decoded.encoding, .utf8)
        XCTAssertEqual(TextCodec.encode(decoded.text, encoding: decoded.encoding, hasBOM: false, lineEnding: .lf), latin1)
    }

    func testOldMacLineEndings() throws {
        let decoded = try XCTUnwrap(TextCodec.decode(Data("a\rb\r".utf8)))
        XCTAssertEqual(decoded.lineEnding, .cr)
        XCTAssertEqual(decoded.text, "a\nb\n")
    }

    func testUnrepresentableTextFailsToEncode() {
        XCTAssertNil(TextCodec.encode("日本語", encoding: .isoLatin1, hasBOM: false, lineEnding: .lf))
    }
}

extension TextCodecTests {
    func testUTF32IsNotMistakenForUTF16() throws {
        let original = try XCTUnwrap("añb\n".data(using: .utf32))
        let decoded = try XCTUnwrap(TextCodec.decode(original))
        XCTAssertEqual(decoded.encoding, .utf32)
        XCTAssertEqual(decoded.text, "añb\n")
    }
}
