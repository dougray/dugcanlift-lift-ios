import SwiftUI
import Vision
import VisionKit

/// Apple's on-device scanner for retail barcodes (VisionKit). Reports the
/// first code and stops; LIFT keeps only the digits it read. Nothing the camera
/// sees leaves the phone, and no frame is kept. If the camera can't start, or
/// goes away mid-scan, it says so once through `onUnavailable` instead of
/// leaving a dark screen with only Cancel on it.
///
/// UPC-A has no symbology of its own here: Vision reports it as EAN-13 with a
/// leading zero, which `Barcode` strips. UPC-E is the one that needs saying,
/// because its eight digits are otherwise read as EAN-8 (ruling R1).
struct BarcodeScannerView: UIViewControllerRepresentable {
    let onCode: (String, BarcodeSymbology?) -> Void
    let onUnavailable: () -> Void

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
            do {
                try scanner.startScanning()
            } catch {
                context.coordinator.becameUnavailable()
            }
        }
    }

    /// Cancel, a swipe, or a code: whichever way the cover goes, the camera
    /// stops with it.
    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        coordinator.finished = true
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode, onUnavailable: onUnavailable) }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String, BarcodeSymbology?) -> Void
        let onUnavailable: () -> Void
        var finished = false

        init(onCode: @escaping (String, BarcodeSymbology?) -> Void, onUnavailable: @escaping () -> Void) {
            self.onCode = onCode
            self.onUnavailable = onUnavailable
        }

        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            report(addedItems, from: scanner)
        }

        /// A code first seen before its digits were read arrives here when
        /// they are.
        func dataScanner(_ scanner: DataScannerViewController, didUpdate updatedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            report(updatedItems, from: scanner)
        }

        func dataScanner(_ scanner: DataScannerViewController,
                         becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            becameUnavailable()
        }

        /// Once, whichever way it happens. Next turn rather than now, because
        /// a failed start is found inside SwiftUI's update pass, where the
        /// parent's state must not change.
        func becameUnavailable() {
            guard !finished else { return }
            finished = true
            let onUnavailable = onUnavailable
            DispatchQueue.main.async { onUnavailable() }
        }

        /// The first barcode with digits wins; everything after it is ignored.
        private func report(_ items: [RecognizedItem], from scanner: DataScannerViewController) {
            guard !finished else { return }
            for item in items {
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
