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

    func testTheMessageIsTheSharedWording() {
        XCTAssertEqual(Barcode.didNotScanCleanlyMessage, "That barcode didn't scan cleanly. Try again.")
    }
}
