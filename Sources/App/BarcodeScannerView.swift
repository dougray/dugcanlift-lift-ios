import SwiftUI
import Vision
import VisionKit

/// Apple's on-device scanner for retail barcodes (VisionKit). Reports the
/// first code and stops; LIFT keeps only the digits it read. Nothing the camera
/// sees leaves the phone, and no frame is kept.
///
/// UPC-A has no symbology of its own here: Vision reports it as EAN-13 with a
/// leading zero, which `Barcode` strips. UPC-E is the one that needs saying,
/// because its eight digits are otherwise read as EAN-8 (ruling R1).
struct BarcodeScannerView: UIViewControllerRepresentable {
    let onCode: (String, BarcodeSymbology?) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.ean13, .ean8, .upce])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    /// Starting before the scanner is on screen fails, so it starts here, once
    /// SwiftUI has put it in the hierarchy, and never again after a code.
    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if !scanner.isScanning, !context.coordinator.finished {
            try? scanner.startScanning()
        }
    }

    /// Cancel, a swipe, or a code: whichever way the cover goes, the camera
    /// stops with it.
    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        coordinator.finished = true
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String, BarcodeSymbology?) -> Void
        var finished = false

        init(onCode: @escaping (String, BarcodeSymbology?) -> Void) { self.onCode = onCode }

        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            guard !finished else { return }
            for item in addedItems {
                guard case .barcode(let barcode) = item, let value = barcode.payloadStringValue else { continue }
                finished = true
                scanner.stopScanning()
                let symbology: BarcodeSymbology? = barcode.observation.symbology == .upce ? .upce : nil
                onCode(value, symbology)
                return
            }
        }
    }
}
