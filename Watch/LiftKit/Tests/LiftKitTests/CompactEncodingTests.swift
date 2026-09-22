import XCTest
import Compression
@testable import LiftKit

final class CompactEncodingTests: XCTestCase {

    func testBase64URLHasNoPaddingOrURLUnsafeCharacters() {
        // 0xFB 0xFF encodes to "+/8=" in standard base64 — one character of
        // each kind this has to rewrite, plus padding to strip.
        let data = Data([0xFB, 0xFF])
        XCTAssertEqual(data.base64EncodedString(), "+/8=")
        XCTAssertEqual(CompactEncoding.base64URL(data), "-_8")
    }

    func testDeflateRawRoundTripsThroughTheSystemInflater() throws {
        let original = String(repeating: "Chicken breast, roasted", count: 40).data(using: .utf8)!
        let deflated = try XCTUnwrap(CompactEncoding.deflateRaw(original))
        XCTAssertLessThan(deflated.count, original.count)

        // Inflate with the matching system algorithm. If this round-trips,
        // the bytes are a stream the PWA's DecompressionStream('deflate-raw')
        // can read, which is the only property that matters.
        let capacity = original.count * 2
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { destination.deallocate() }
        let written = deflated.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(destination, capacity, base, deflated.count,
                                             nil, COMPRESSION_ZLIB)
        }
        XCTAssertEqual(Data(bytes: destination, count: written), original)
    }

    func testDeflateRawReturnsNilForEmptyInput() {
        XCTAssertNil(CompactEncoding.deflateRaw(Data()))
    }
}
