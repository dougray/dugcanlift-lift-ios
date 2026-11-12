import SwiftUI
import LiftCore

/// The licenses the street maps carry: MapLibre Native's BSD 2-Clause text,
/// Noto Sans's SIL Open Font License, and the OpenStreetMap / OpenFreeMap
/// credit. Read from `Resources/MapLicenses.txt`, which is bundled with the app.
struct MapLicenseView: View {
    static let fileName = "MapLicenses"

    private let text: String = {
        guard let url = Bundle.main.url(forResource: fileName, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "© OpenStreetMap contributors · OpenFreeMap"
        }
        return text
    }()

    var body: some View {
        ScrollView {
            Text(text)
                .font(Theme.detail)
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .background(Theme.background)
        .navigationTitle("Map licenses")
        .navigationBarTitleDisplayMode(.inline)
    }
}
