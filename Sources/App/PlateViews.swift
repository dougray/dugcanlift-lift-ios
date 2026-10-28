import SwiftUI
import LiftCore

/// "Per side: 45 · 25" under a set's weight while it is being edited, for a
/// lift on a bar. Reads the plates for the unit on screen, and follows a change
/// made in Settings without being told.
struct PlateLine: View {
    let weightKg: Double
    let bar: BarKind
    let unit: WeightUnit

    @AppStorage(PlateSetup.key(for: .pounds)) private var poundSetup = Data()
    @AppStorage(PlateSetup.key(for: .kilograms)) private var kiloSetup = Data()

    private var setup: PlateSetup {
        let data = unit == .pounds ? poundSetup : kiloSetup
        return (try? JSONDecoder().decode(PlateSetup.self, from: data)) ?? .standard(for: unit)
    }

    var body: some View {
        if let line = PlateMath.load(total: unit.fromKilograms(weightKg), bar: bar, setup: setup)
            .line(unit: unit) {
            Text(line)
                .font(Theme.detail)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(line.replacingOccurrences(of: " · ", with: ", "))
        }
    }
}

/// Settings › Plates: what each bar weighs and which plates are on the rack,
/// for the weight unit LIFT is showing.
struct PlateSettingsView: View {
    @AppStorage("weightUnit") private var unitRaw = WeightUnit.pounds.rawValue
    @State private var setup = PlateSetup.standard(for: .pounds)

    private var unit: WeightUnit { WeightUnit(rawValue: unitRaw) ?? .kilograms }

    var body: some View {
        List {
            Section {
                ForEach(BarKind.allCases) { bar in
                    LabeledContent(bar.displayName) {
                        HStack(spacing: 6) {
                            TextField("0", value: barBinding(bar), format: .number)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 80)
                                .accessibilityLabel("\(bar.displayName) weight, \(unit.abbreviation)")
                            Text(unit.abbreviation)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                    }
                }
            } header: {
                Text("Bars")
            } footer: {
                Text("What the bar weighs on its own. Smith machine bars vary; check yours.")
            }

            Section {
                ForEach(setup.plates, id: \.weight) { plate in
                    Stepper(value: pairsBinding(plate.weight), in: 0...PlateSetup.mostPairs) {
                        LabeledContent("\(PlateMath.text(plate.weight)) \(unit.abbreviation)",
                                       value: plate.pairs == 0 ? "None"
                                           : "\(plate.pairs) pair\(plate.pairs == 1 ? "" : "s")")
                    }
                }
            } header: {
                Text("Plates")
            } footer: {
                Text("Pairs, because a plate goes on each end. When your plates can't make a set's weight exactly, LIFT shows the closest load under it.")
            }

            Section {
                Button("Reset to a standard gym") {
                    setup = .standard(for: unit)
                    setup.save(for: unit)
                }
            }
        }
        .navigationTitle("Plates")
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDoneButton()
        .onAppear { setup = PlateSetup.load(for: unit) }
        .onChange(of: unitRaw) { setup = PlateSetup.load(for: unit) }
    }

    private func barBinding(_ bar: BarKind) -> Binding<Double> {
        Binding(
            get: { setup.barWeight(bar) },
            set: { setup.setBar(bar, weight: $0); setup.save(for: unit) }
        )
    }

    private func pairsBinding(_ weight: Double) -> Binding<Int> {
        Binding(
            get: { setup.pairs(of: weight) },
            set: { setup.set(pairs: $0, of: weight); setup.save(for: unit) }
        )
    }
}
