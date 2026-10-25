import XCTest
@testable import Lift

final class BarcodeQueryTests: XCTestCase {
    func testAValidCodeTypedIntoSearchIsABarcode() {
        XCTAssertEqual(BarcodeQuery.barcodeDigits(in: "036000291452"), "036000291452")
        XCTAssertEqual(BarcodeQuery.barcodeDigits(in: " 0360-0029-1452 "), "036000291452")
    }
    func testDigitsThatFailTheCheckAreJustASearch() {
        XCTAssertNil(BarcodeQuery.barcodeDigits(in: "036000291453"))
    }
    func testWordsAndShortNumbersAreJustASearch() {
        XCTAssertNil(BarcodeQuery.barcodeDigits(in: "oats"))
        XCTAssertNil(BarcodeQuery.barcodeDigits(in: "2000"))
        XCTAssertNil(BarcodeQuery.barcodeDigits(in: "7up 12345678"))
    }
}
