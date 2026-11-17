import SwiftUI

/// Settings > Heart rate: where a run's heart rate comes from.
///
/// Tracked and shown, never targeted: nothing here sets a zone or a limit. The
/// choice is stored as JSON in `@AppStorage` (`HeartRateStorage`), and a value
/// this build cannot read is Automatic.
struct HeartRateSettingsSection: View {
    /// Apple Watch is offered when a watch is paired and LIFT is installed on
    /// it (`PairedWatchAvailability`, read from the app's one `WCSession`), and
    /// while it is the chosen setting.
    private var offersWatch: Bool {
        HeartRateWatchRow.shows(ready: PairedWatchAvailability().isWatchAppReady, setting: setting)
    }

    @AppStorage(HeartRateStorage.settingKey) private var settingRaw = HeartRateStorage.defaultSetting
    @AppStorage(HeartRateStorage.devicesKey) private var devicesRaw = HeartRateStorage.defaultDevices

    /// The app's one radio, shared with a run in progress.
    private var central: HeartRateCentral { .shared }
    @State private var isAdding = false

    private var setting: HeartRateSetting { HeartRateStorage.setting(from: settingRaw) }
    private var devices: [AddedHeartRateDevice] { HeartRateStorage.devices(from: devicesRaw) }

    var body: some View {
        Section {
            choice("Automatic", is: .automatic)
            choice("Off", is: .off)
            ForEach(devices) { device in
                choice(device.name, is: .device(device.id))
                    .swipeActions {
                        Button("Remove", role: .destructive) { remove(device) }
                    }
            }
            if offersWatch {
                choice("Apple Watch", is: .watch)
            }
            Button("Add a Bluetooth heart rate device") { isAdding = true }
                .sheet(isPresented: $isAdding) {
                    AddHeartRateDeviceSheet(central: central, alreadyAdded: Set(devices.map(\.id))) { device in
                        devicesRaw = HeartRateStorage.string(for: HeartRateStorage.adding(device, to: devices))
                    }
                }
        } header: {
            Text("Heart rate")
        } footer: {
            Text("Automatic uses a device you've added when it's nearby, then LIFT on your Apple Watch. Bands that save heart rate to Apple Health fill in the summary after the run.")
        }
    }

    private func choice(_ title: String, is value: HeartRateSetting) -> some View {
        Button {
            settingRaw = HeartRateStorage.string(for: value)
        } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if setting == value {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(setting == value ? .isSelected : [])
    }

    private func remove(_ device: AddedHeartRateDevice) {
        settingRaw = HeartRateStorage.string(for: HeartRateStorage.setting(setting, afterRemoving: device.id))
        devicesRaw = HeartRateStorage.string(for: devices.filter { $0.id != device.id })
    }
}
