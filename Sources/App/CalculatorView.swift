import SwiftUI
import WidgetKit
import LiftCore

enum BiologicalSex: String, CaseIterable, Identifiable {
    case male = "Male"
    case female = "Female"

    var id: String { rawValue }
}

/// Multipliers and calorie math mirror the web calculator at
/// dugcanlift-site/calculator.html exactly — same Mifflin-St Jeor formula,
/// same activity multipliers, same goal adjustments. Keep the two in sync.
enum ActivityLevel: String, CaseIterable, Identifiable {
    case sedentary = "Sedentary"
    case light = "Light"
    case moderate = "Moderate"
    case heavy = "Heavy"
    case veryActive = "Very Active"

    var id: String { rawValue }

    var multiplier: Double {
        switch self {
        case .sedentary: 1.2
        case .light: 1.375
        case .moderate: 1.55
        case .heavy: 1.725
        case .veryActive: 1.9
        }
    }
}

enum CalorieGoal: String, CaseIterable, Identifiable {
    case cut = "Cut"
    case maintain = "Maintain"
    case bulk = "Bulk"

    var id: String { rawValue }

    var adjustment: Double {
        switch self {
        case .cut: -500
        case .maintain: 0
        case .bulk: 300
        }
    }
}

struct MacroResult {
    let calories: Double
    let proteinG: Double
    let fatG: Double
    let carbsG: Double
    let fiberG: Double
}

/// Pushed from Home's "Set my goal" prompt. Activity and Goal are each five
/// and three pills respectively that don't all fit on a phone width, so both
/// rows scroll horizontally — matching the Android build.
struct CalculatorView: View {
    @Environment(\.dismiss) private var dismiss

    /// Settings' units, so a metric lifter isn't converting by hand. Weight
    /// follows the weight setting; height follows distance (kilometres means
    /// centimetres, miles means feet and inches).
    @AppStorage("weightUnit") private var weightUnitRaw = WeightUnit.pounds.rawValue
    @AppStorage("distanceUnit") private var distanceUnitRaw = DistanceUnit.miles.rawValue
    private var weightUnit: WeightUnit { WeightUnit(rawValue: weightUnitRaw) ?? .pounds }
    private var metricHeight: Bool { DistanceUnit(rawValue: distanceUnitRaw) == .kilometers }

    @State private var sex: BiologicalSex = .male
    @State private var age = ""
    @State private var weightText = ""
    @State private var heightFt = ""
    @State private var heightIn = ""
    @State private var heightCmText = ""
    @State private var activity: ActivityLevel = .sedentary
    @State private var goal: CalorieGoal = .maintain

    private enum Field: Hashable { case age, weight, heightFt, heightIn, heightCm }
    @FocusState private var focusedField: Field?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.cardSpacing) {
                    sexToggle

                    field("Age", text: $age, keyboard: .numberPad, focus: .age)
                    field("Weight (\(weightUnit.abbreviation))", text: $weightText, keyboard: .decimalPad, focus: .weight)
                    if metricHeight {
                        field("Height (cm)", text: $heightCmText, keyboard: .decimalPad, focus: .heightCm)
                    } else {
                        field("Height (ft)", text: $heightFt, keyboard: .numberPad, focus: .heightFt)
                        field("Height (in)", text: $heightIn, keyboard: .numberPad, focus: .heightIn)
                    }

                    Text("Activity")
                        .font(Theme.sectionLabel)
                        .foregroundStyle(Theme.textPrimary)
                    chipRow(ActivityLevel.allCases, selection: activity) { activity = $0 }

                    Text("Goal")
                        .font(Theme.sectionLabel)
                        .foregroundStyle(Theme.textPrimary)
                    chipRow(CalorieGoal.allCases, selection: goal) { goal = $0 }

                    if let result {
                        resultCard(result)
                    } else {
                        Text("Enter age, weight, and height to see your numbers.")
                            .font(Theme.body)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 40)
                .readableContentWidth()
            }
            .appScreen()
            .keyboardDoneButton()
            .navigationTitle("Macro Calculator")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    // MARK: Sex toggle

    private var sexToggle: some View {
        HStack(spacing: 10) {
            ForEach(BiologicalSex.allCases) { option in
                LiftChip(label: option.rawValue, isSelected: sex == option) {
                    sex = option
                }
            }
        }
        .padding(.top, 8)
    }

    // MARK: Fields

    /// The label stays visible above the field once something is typed in
    /// it; a placeholder alone vanished, leaving "70" with no unit.
    private func field(_ prompt: String, text: Binding<String>, keyboard: UIKeyboardType,
                        focus: Field) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(prompt)
                .scaledFont(size: 14)
                .foregroundStyle(Theme.textSecondary)
                .accessibilityHidden(true)
            TextField(prompt, text: text)
                .keyboardType(keyboard)
                .focused($focusedField, equals: focus)
                .font(Theme.body)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .background {
                    // textSecondary, not hairline: a field's edge needs 3:1.
                    RoundedRectangle(cornerRadius: Theme.chipRadius)
                        .stroke(focusedField == focus ? Theme.accent : Theme.textSecondary.opacity(0.75),
                                lineWidth: focusedField == focus ? 2 : 1)
                }
                .accessibilityLabel(prompt)
        }
    }

    // MARK: Chip rows

    private func chipRow<T: Hashable & Identifiable & RawRepresentable>(
        _ items: [T], selection: T, onSelect: @escaping (T) -> Void
    ) -> some View where T.RawValue == String {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(items) { item in
                    LiftChip(label: item.rawValue, isSelected: item == selection) {
                        onSelect(item)
                    }
                }
            }
        }
    }

    // MARK: Result

    private var result: MacroResult? {
        guard let age = Double(age), age > 0,
              let enteredWeight = Double(weightText), enteredWeight > 0,
              let heightCm = enteredHeightCm, heightCm > 0
        else { return nil }

        let weightKg = weightUnit.toKilograms(enteredWeight)
        // The protein rule below is per pound of bodyweight, whatever unit
        // the weight was typed in.
        let weightLb = WeightUnit.pounds.fromKilograms(weightKg)

        let bmr: Double = switch sex {
        case .male: (10 * weightKg) + (6.25 * heightCm) - (5 * age) + 5
        case .female: (10 * weightKg) + (6.25 * heightCm) - (5 * age) - 161
        }

        let tdee = bmr * activity.multiplier
        let calories = (tdee + goal.adjustment).rounded()

        let proteinG = (0.8 * weightLb).rounded()
        let fatG = (calories * 0.25 / 9).rounded()
        let carbsG = max((calories - proteinG * 4 - fatG * 9) / 4, 0).rounded()
        let fiberG = (calories / 1000 * 14).rounded()

        return MacroResult(calories: calories, proteinG: proteinG, fatG: fatG,
                            carbsG: carbsG, fiberG: fiberG)
    }

    private var enteredHeightCm: Double? {
        if metricHeight {
            return Double(heightCmText)
        }
        guard let feet = Double(heightFt), feet > 0 else { return nil }
        return ((feet * 12) + (Double(heightIn) ?? 0)) * 2.54
    }

    private func resultCard(_ result: MacroResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            LiftCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(Int(result.calories)) kcal / day")
                        .scaledFont(size: 26, weight: .bold)
                        .foregroundStyle(Theme.textPrimary)
                    StatRow(label: "Protein", value: "\(Int(result.proteinG)) g")
                    StatRow(label: "Fat", value: "\(Int(result.fatG)) g")
                    StatRow(label: "Carbs", value: "\(Int(result.carbsG)) g")
                    StatRow(label: "Fiber", value: "\(Int(result.fiberG)) g")
                }
            }

            Button {
                save(result)
            } label: {
                Text("Save as my goal")
                    .scaledFont(size: 16, weight: .bold)
                    .foregroundStyle(Theme.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.chipRadius))
            }
            .buttonStyle(.plain)
        }
    }

    private func save(_ result: MacroResult) {
        MacroGoals.calories = result.calories
        MacroGoals.protein = result.proteinG
        MacroGoals.fat = result.fatG
        MacroGoals.carbs = result.carbsG
        MacroGoals.fiber = result.fiberG
        MacroGoals.isSet = true
        WidgetCenter.shared.reloadAllTimelines()
        dismiss()
    }
}
