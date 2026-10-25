import SwiftUI

/// The words for what LIFT remembers about a barcode, in one place. The
/// editor's "Edit remembered food" and the scanner's amount step both offer to
/// forget a code, and the question must read the same wherever it is asked.
enum RememberedFoodWords {
    static let editTitle = "Edit remembered food"
    static let forgetButton = "Forget this barcode"
    static let forgetTitle = "Forget this barcode?"
    static let forgetMessage = "Foods you've already logged stay in your log."
    static let forgetConfirm = "Forget"
    static let cancel = "Cancel"
}

extension View {
    /// The one confirmation before `RememberedFoods.forget`. `forget` runs only
    /// on Forget; Cancel does nothing.
    func forgetBarcodeConfirmation(isPresented: Binding<Bool>,
                                   forget: @escaping () -> Void) -> some View {
        confirmationDialog(RememberedFoodWords.forgetTitle, isPresented: isPresented,
                           titleVisibility: .visible) {
            Button(RememberedFoodWords.forgetConfirm, role: .destructive, action: forget)
            Button(RememberedFoodWords.cancel, role: .cancel) {}
        } message: {
            Text(RememberedFoodWords.forgetMessage)
        }
    }
}
