import Foundation

/// Whether what was typed into food search is a barcode. 8–14 digits once
/// spaces and dashes go, and a valid check digit: anything else is a name
/// search, so a mistyped number just searches rather than raising an error.
enum BarcodeQuery {
    static func barcodeDigits(in query: String) -> String? {
        let compact = query.filter { !$0.isWhitespace && $0 != "-" }
        guard (8...14).contains(compact.count), compact.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        guard case .success = Barcode.read(compact) else { return nil }
        return compact
    }
}
