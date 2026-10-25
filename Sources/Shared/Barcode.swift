import Foundation

enum BarcodeSymbology: Equatable { case ean13, ean8, upce }

enum BarcodeProblem: Error, Equatable { case didNotScanCleanly }

/// A retail barcode read the one way every LIFT build reads it (in-house
/// programme, "Reading a barcode"): digits only, the GS1 check digit checked
/// before anything is looked up, then leading zeros stripped so a product's
/// UPC-A, EAN-13 and GTIN-14 spellings meet. A code that fails is *didn't scan
/// cleanly*, never *not found*. All zeros passes the arithmetic and fails by
/// rule. `Tests/Fixtures/barcodes.json` is the shared fixture; never
/// regenerate it from this code.
///
/// Two spellings of one product are the same `Barcode`: equality and hashing
/// are on `normalised` alone, which is also what is stored and what a ref
/// carries. `printed` is only for showing the code to the person.
struct Barcode: Equatable, Hashable {
    let normalised: String
    /// The digits as the packet prints them, leading zeros kept (a UPC-E's
    /// eight; a UPC-A's twelve even when the scanner called it EAN-13, see
    /// `printedDigits`). Never stored, compared or looked up.
    let printed: String

    static let didNotScanCleanlyMessage = "That barcode didn't scan cleanly. Try again."

    static func == (lhs: Barcode, rhs: Barcode) -> Bool { lhs.normalised == rhs.normalised }
    func hash(into hasher: inout Hasher) { hasher.combine(normalised) }

    /// Reads an 8-digit code as EAN-8 only; it is expanded as UPC-E only when
    /// the scanner says `symbology == .upce`. Under `.upce` a 12- or 13-digit
    /// payload is checked as it is, because the scanner may hand over the
    /// expansion rather than the eight digits.
    static func read(_ raw: String, symbology: BarcodeSymbology? = nil) -> Result<Barcode, BarcodeProblem> {
        let digits = raw.filter(\.isASCII).filter(\.isNumber)
        guard digits.count == raw.filter({ !$0.isWhitespace && $0 != "-" }).count else {
            return .failure(.didNotScanCleanly)
        }
        if symbology == .upce {
            if digits.count == 12 || digits.count == 13 { return checked(digits, printed: digits) }
            guard let full = expandUPCE(digits) else { return .failure(.didNotScanCleanly) }
            return checked(full, printed: digits)
        }
        return checked(digits, printed: printedDigits(payload: digits, symbology: symbology))
    }

    /// What to show for a payload. Vision reports a UPC-A as EAN-13 with a
    /// leading "0", so when the scanner says EAN-13 and the payload is thirteen
    /// digits starting "0", the packet's own twelve are the last twelve. Typed
    /// digits (no symbology) are shown exactly as given. Display only:
    /// `normalised` is the same either way.
    static func printedDigits(payload: String, symbology: BarcodeSymbology?) -> String {
        guard symbology == .ean13, payload.count == 13, payload.hasPrefix("0") else { return payload }
        return String(payload.dropFirst())
    }

    /// UPC-E (number system, six digits, check) to UPC-A. Nil unless 8 digits
    /// with number system 0 or 1.
    static func expandUPCE(_ code: String) -> String? {
        let d = code.compactMap(\.wholeNumberValue)
        guard d.count == 8, d[0] == 0 || d[0] == 1 else { return nil }
        let (ns, m, check) = (d[0], Array(d[1...6]), d[7])
        let body: [Int]
        switch m[5] {
        case 0, 1, 2: body = [m[0], m[1], m[5], 0, 0, 0, 0, m[2], m[3], m[4]]
        case 3:       body = [m[0], m[1], m[2], 0, 0, 0, 0, 0, m[3], m[4]]
        case 4:       body = [m[0], m[1], m[2], m[3], 0, 0, 0, 0, 0, m[4]]
        default:      body = [m[0], m[1], m[2], m[3], m[4], 0, 0, 0, 0, m[5]]
        }
        return ([ns] + body + [check]).map(String.init).joined()
    }

    private static func checked(_ digits: String, printed: String) -> Result<Barcode, BarcodeProblem> {
        let d = digits.compactMap(\.wholeNumberValue)
        guard [8, 12, 13, 14].contains(d.count), d.contains(where: { $0 != 0 }) else {
            return .failure(.didNotScanCleanly)
        }
        let body = d.dropLast()
        let sum = body.reversed().enumerated().reduce(0) { $0 + $1.element * ($1.offset % 2 == 0 ? 3 : 1) }
        guard (10 - sum % 10) % 10 == d.last else { return .failure(.didNotScanCleanly) }
        let stripped = String(digits.drop(while: { $0 == "0" }))
        return .success(Barcode(normalised: stripped, printed: printed))
    }
}
