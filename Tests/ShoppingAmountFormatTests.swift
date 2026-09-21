import XCTest
import LiftCore
@testable import Lift

/// The shopping list prints what LIFT web (`trimNum`) and LIFT Android
/// (`cookDisplay`) print: two decimals at most, whole numbers bare.
final class ShoppingAmountFormatTests: XCTestCase {

    func testRoundsToTwoDecimals() {
        XCTAssertEqual(ShoppingAmountFormat.amount(416.66666666666663), "416.67")
        XCTAssertEqual(ShoppingAmountFormat.amount(1.6666666666666665), "1.67")
    }

    func testWholeNumbersPrintBare() {
        XCTAssertEqual(ShoppingAmountFormat.amount(3), "3")
        XCTAssertEqual(ShoppingAmountFormat.amount(1200), "1200")
    }

    func testTrailingZerosAreDropped() {
        XCTAssertEqual(ShoppingAmountFormat.amount(2.5), "2.5")
        XCTAssertEqual(ShoppingAmountFormat.amount(2.999), "3")
        XCTAssertEqual(ShoppingAmountFormat.amount(0.001), "0")
    }

    /// Half rounds up on the decimal the value prints as, as Android's
    /// `BigDecimal.valueOf` does, not on the binary value just below it.
    func testHalfRoundsUpOnTheShortestDecimal() {
        XCTAssertEqual(ShoppingAmountFormat.amount(1.005), "1.01")
        XCTAssertEqual(ShoppingAmountFormat.amount(0.125), "0.13")
    }

    /// Always a `.` decimal and no grouping, whatever the device's locale.
    func testIsLocaleInvariant() {
        XCTAssertEqual(ShoppingAmountFormat.amount(1234.5), "1234.5")
    }

    func testLabelKeepsCookFormatsLayout() {
        let amounts: [String: Double] = [
            "g": 416.66666666666663,
            IngredientParser.countUnit: 1.6666666666666665,
        ]
        // The count sentinel sorts first and prints bare, never its key.
        XCTAssertEqual(ShoppingAmountFormat.label(amounts), "1.67 + 416.67 g")
        XCTAssertEqual(ShoppingAmountFormat.label(["cup": 2.5, "tbsp": 3]), "2.5 cup + 3 tbsp")
    }

    /// The rounding is display only: `CookFormat.trimmed`, which writes
    /// ingredient text `IngredientParser` reads back, keeps its precision.
    func testCookFormatTrimmedIsUnchanged() {
        XCTAssertEqual(CookFormat.trimmed(416.66666666666663), "416.667")
    }
}
