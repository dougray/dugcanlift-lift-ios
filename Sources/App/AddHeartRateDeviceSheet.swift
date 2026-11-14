import SwiftUI

/// The scan list: a Bluetooth heart rate device is added by the person, from
/// here, and never connected to otherwise.
struct AddHeartRateDeviceSheet: View {
    let central: HeartRateCentral
    /// Devices already in the list, so they are not offered again.
    let alreadyAdded: Set<UUID>
    let onAdd: (AddedHeartRateDevice) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var found: [DiscoveredDevice] = []

    private var offered: [DiscoveredDevice] { found.filter { !alreadyAdded.contains($0.id) } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if offered.isEmpty {
                        HStack(spacing: 12) {
                            if central.radio.isLooking { ProgressView() }
                            Text(central.radio.emptyListMessage)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(offered) { device in
                        Button {
                            onAdd(AddedHeartRateDevice(id: device.id, name: device.name))
                            dismiss()
                        } label: {
                            Text(device.name).foregroundStyle(.primary)
                        }
                    }
                } footer: {
                    Text("Turn on your strap, or heart rate broadcast on your watch.")
                }
            }
            .navigationTitle("Add a device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task {
            for await list in central.scan() { found = list }
        }
        .onDisappear { central.stopScan() }
    }
}
