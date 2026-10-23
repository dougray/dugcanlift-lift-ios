import XCTest
@testable import Lift

// Tests/Fixtures/barcodes.json is typed by hand from published examples, with
// the check digits verified independently. It is the cross-build contract for
// reading a barcode: never regenerate it from the code under test.
final class BarcodeTests: XCTestCase {

    private struct Fixture: Decodable {
        struct Valid: Decodable { let raw: String; let normalised: String }
        struct UPCE: Decodable { let raw: String; let expandsTo: String; let normalised: String }
        struct Invalid: Decodable { let raw: String }
        let valid: [Valid]; let upce: [UPCE]; let invalid: [Invalid]
    }

    private func fixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "barcodes", withExtension: "json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testEveryValidCodeNormalises() throws {
        for c in try fixture().valid {
            XCTAssertEqual(try Barcode.read(c.raw).get().normalised, c.normalised, c.raw)
        }
    }

    func testUPCEExpandsThenChecks() throws {
        for c in try fixture().upce {
            XCTAssertEqual(Barcode.expandUPCE(c.raw), c.expandsTo, c.raw)
            XCTAssertEqual(try Barcode.read(c.raw, symbology: .upce).get().normalised, c.normalised)
        }
    }

    func testEveryInvalidCodeDidNotScanCleanly() throws {
        for c in try fixture().invalid {
            XCTAssertEqual(Barcode.read(c.raw), .failure(.didNotScanCleanly), c.raw)
        }
    }

    func testTheSameProductPrintedThreeWaysMeets() throws {
        let a = try Barcode.read("036000291452").get()
        XCTAssertEqual(a, try Barcode.read("0036000291452").get())
        XCTAssertEqual(a, try Barcode.read("00036000291452").get())
    }

    func testAnEightDigitCodeIsEAN8UnlessTheScannerSaysUPCE() throws {
        // 01234565 is valid both as EAN-8 and as UPC-E, so only the scanner's
        // symbology can say which; typed digits are read as EAN-8.
        XCTAssertEqual(try Barcode.read("01234565").get().normalised, "1234565")
        XCTAssertEqual(try Barcode.read("01234565", symbology: .upce).get().normalised, "12345000065")
        XCTAssertEqual(try Barcode.read("73513537").get().normalised, "73513537")
    }

    /// Vision may hand over a UPC-E already expanded to its UPC-A (or EAN-13)
    /// spelling. That is checked as it is; eight digits are expanded first.
    func testUPCEAlsoReadsTheExpansionAsItIs() throws {
        XCTAssertEqual(try Barcode.read("012345000065", symbology: .upce).get().normalised, "12345000065")
        XCTAssertEqual(try Barcode.read("0012345000065", symbology: .upce).get().normalised, "12345000065")
        XCTAssertEqual(try Barcode.read("01234565", symbology: .upce).get().normalised, "12345000065")
        XCTAssertEqual(Barcode.read("012345000066", symbology: .upce), .failure(.didNotScanCleanly),
                       "a twelve-digit payload still has its check digit checked")
        XCTAssertEqual(Barcode.read("0123456", symbology: .upce), .failure(.didNotScanCleanly))
        XCTAssertEqual(Barcode.read("00012345000065", symbology: .upce), .failure(.didNotScanCleanly),
                       "UPC-E is never fourteen digits")
    }

    /// Shown as it is printed, leading zeros and all; compared, hashed and
    /// stored by the normalised code only.
    func testTheDigitsAsReadAreKeptForShowing() throws {
        let a = try Barcode.read("036000291452").get()
        XCTAssertEqual(a.printed, "036000291452")
        XCTAssertEqual(a.normalised, "36000291452")
        let b = try Barcode.read("0036000291452").get()
        XCTAssertEqual(b.printed, "0036000291452")
        XCTAssertEqual(a, b)
        XCTAssertEqual(Set([a, b]).count, 1)
        XCTAssertEqual(try Barcode.read("0 36000-29145 2").get().printed, "036000291452",
                       "spaces and hyphens are not part of the code")
        XCTAssertEqual(try Barcode.read("01234565", symbology: .upce).get().printed, "01234565",
                       "a UPC-E shows the eight digits on the pack")
    }

    func testTheMessageIsTheSharedWording() {
        XCTAssertEqual(Barcode.didNotScanCleanlyMessage, "That barcode didn't scan cleanly. Try again.")
    }
}
