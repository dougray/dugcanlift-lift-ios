import AVFoundation
import SwiftData
import SwiftUI
import WidgetKit
import VisionKit
import LiftCore
import LiftReference

/// Search the bundled food.db and log a chosen amount straight onto today's
/// log — the actual "log a new food" flow, built for the first time here.
///
/// Two stages in one view, the same shape as `RecipePickerView`/
/// `ExercisePickerView`: a searchable list, then a picked-item detail. Gram-based
/// from the start, per the spec's explicit decision — there is no serving-count
/// stepper here, only a plain amount in the person's preferred unit
/// (`ServingUnit`, Settings > Serving size), converted to the canonical gram
/// amount `FoodEntry.amountGrams` stores.
///
/// A food the database does not have is added by hand: "Add food by hand" sits
/// above the results, always, and a search that finds nothing offers to add
/// what was typed. Both open `FoodEntryEditorView` in its new-entry mode —
/// macros per 100 g, as LIFT web's form takes them — whose rules are
/// `FoodEntryEdit`'s, and logging it closes this sheet as logging a database
/// food does.
///
/// The amount step serves a `LoggableFood`: a library record, or a food the
/// person remembered against a barcode. A remembered food says so under its
/// name and offers Edit and Forget; nothing else about the step differs.
///
/// **A barcode** arrives two ways and is looked up one way
/// (`BarcodeLookup`): "Scan a barcode", above "Add food by hand" on a phone
/// that can scan, or the digits typed into the search field
/// (`BarcodeQuery`). A remembered code opens the amount step; an unknown one
/// says so and offers to enter it once, which opens the by-hand form with the
/// code attached; a code that fails its check digit didn't scan cleanly. One
/// presentation at a time: the scanner's cover is gone before its alert, the
/// amount step or the form appears, because SwiftUI drops a presentation
/// started while another is still animating away.
struct FoodSearchView: View {
    let mealType: MealType
    var onLogged: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @AppStorage("servingUnit") private var servingUnitRaw = ServingUnit.grams.rawValue

    @State private var query = ""
    /// What the last search found. Its foods are the closest ones, not
    /// matches, when no food had every word typed.
    @State private var found = Self.nothingFound
    @State private var loadFailed = false
    /// True from a keystroke until its search has answered, so "No Results"
    /// (and its button) appears only once a search has really found nothing,
    /// not for the 200 ms debounce before every one.
    @State private var searching = false
    @State private var selected: LoggableFood?
    @State private var amountText = ""
    /// The one sheet food search presents at a time.
    @State private var sheet: Sheet?
    @State private var confirmingForget = false
    /// Set when a food added by hand (with or without a barcode) was logged,
    /// so this sheet closes after the editor's own sheet has gone.
    @State private var loggedNewFood = false
    /// Set when the remembered-food editor saved or forgot, so the amount step
    /// catches up once the editor has gone rather than while it is still on
    /// screen — a forgotten food would otherwise empty the sheet mid-dismissal.
    @State private var editedRememberedCode: String?

    /// The scanner's full-screen cover.
    @State private var scanning = false
    /// What a scan found, held until the cover has gone.
    @State private var scanOutcome: BarcodeLookup.Outcome?
    /// Set when the camera couldn't start or went away mid-scan; said once the
    /// cover has gone.
    @State private var scannerLostCamera = false
    @State private var scanMessage: ScanMessage?
    /// What the typed query is, when it is a barcode; nil for a name search.
    @State private var typedCode: TypedCode?

    private enum Sheet: Identifiable {
        /// A food typed in by hand; the name is the query, or blank.
        case byHand(name: String)
        /// The editor for a remembered food, by its code.
        case remembered(code: String)
        /// A food typed in by hand against a barcode nothing knows yet; saving
        /// logs it and remembers it under the normalised code, and the form
        /// shows the digits as read.
        case byBarcode(Barcode)

        var id: String {
            switch self {
            case .byHand(let name): return "hand:" + name
            case .remembered(let code): return "remembered:" + code
            case .byBarcode(let code): return "barcode:" + code.normalised
            }
        }
    }

    /// The scanner's three answers that need saying.
    private enum ScanMessage: Identifiable {
        case didNotScanCleanly
        case unknown(Barcode)
        case cameraUnavailable

        var id: String {
            switch self {
            case .didNotScanCleanly: return "unclean"
            case .unknown(let code): return "unknown:" + code.normalised
            case .cameraUnavailable: return "camera"
            }
        }

        var text: String {
            switch self {
            case .didNotScanCleanly: return Barcode.didNotScanCleanlyMessage
            case .unknown: return BarcodeLookup.notFoundMessage
            case .cameraUnavailable: return ScanAvailability.unavailableMessage
            }
        }
    }

    /// A typed query that reads as a barcode: remembered, or not known yet.
    private enum TypedCode: Equatable {
        case remembered(LoggableFood)
        case unknown(Barcode)

        /// The code it answers for, normalised.
        var normalised: String? {
            switch self {
            case .remembered(let food): return food.rememberedCode
            case .unknown(let code): return code.normalised
            }
        }
    }

    /// Read fresh each time, so a tap after coming back from Settings sees
    /// the camera as it is now.
    private var scanAvailability: ScanAvailability {
        ScanAvailability.current(isSupported: DataScannerViewController.isSupported,
                                 isAvailable: DataScannerViewController.isAvailable,
                                 cameraAccess: .init(AVCaptureDevice.authorizationStatus(for: .video)))
    }

    private var servingUnit: ServingUnit { ServingUnit(rawValue: servingUnitRaw) ?? .grams }

    var body: some View {
        NavigationStack {
            if let selected {
                amountEntry(for: selected)
            } else {
                searchList
            }
        }
        .sheet(item: $sheet, onDismiss: sheetDismissed) { sheet in
            switch sheet {
            case .byHand(let name):
                FoodEntryEditorView(newNamed: name, mealType: mealType,
                                    preferredUnit: servingUnit) { loggedNewFood = true }
                    .liftAppearance()
            case .remembered(let code):
                if let food = RememberedFoods.find(code: code, in: context) {
                    FoodEntryEditorView(remembering: food, preferredUnit: servingUnit) {
                        editedRememberedCode = code
                    }
                    .liftAppearance()
                }
            case .byBarcode(let code):
                FoodEntryEditorView(newNamed: "", mealType: mealType, preferredUnit: servingUnit,
                                    barcode: code) { loggedNewFood = true }
                    .liftAppearance()
            }
        }
        .fullScreenCover(isPresented: $scanning, onDismiss: scannerDismissed) {
            scannerScreen
        }
        .alert(scanMessage?.text ?? "", isPresented: Binding(
            get: { scanMessage != nil },
            set: { if !$0 { scanMessage = nil } }
        ), presenting: scanMessage) { message in
            switch message {
            case .didNotScanCleanly:
                Button("Try again") { scanning = true }
                Button("Cancel", role: .cancel) {}
            case .unknown(let code):
                Button("Enter it") { enter(code) }
                Button("Cancel", role: .cancel) {}
            case .cameraUnavailable:
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private func sheetDismissed() {
        if let code = editedRememberedCode {
            editedRememberedCode = nil
            refreshSelected(code: code)
        }
        guard loggedNewFood else { return }
        onLogged()
        dismiss()
    }

    // MARK: Scan

    private var scannerScreen: some View {
        NavigationStack {
            BarcodeScannerView { raw, symbology in
                scanOutcome = BarcodeLookup.look(up: raw, symbology: symbology, in: context)
                scanning = false
            } onUnavailable: {
                scannerLostCamera = true
                scanning = false
            }
            .ignoresSafeArea()
            .navigationTitle("Scan a barcode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { scanning = false }
                }
            }
        }
        .liftAppearance()
    }

    /// The first tap on a phone never asked asks for the camera; nothing else
    /// is presented while the system's prompt is up, and the answer decides.
    private func startScan() {
        switch scanAvailability {
        case .ready: scanning = true
        case .needsPermission:
            Task { @MainActor in
                _ = await AVCaptureDevice.requestAccess(for: .video)
                if scanAvailability == .ready {
                    scanning = true
                } else {
                    scanMessage = .cameraUnavailable
                }
            }
        case .unavailable: scanMessage = .cameraUnavailable
        case .unsupported: break
        }
    }

    /// Runs once the cover has gone, so whatever comes next is the only
    /// presentation in flight.
    private func scannerDismissed() {
        if scannerLostCamera {
            scannerLostCamera = false
            scanMessage = .cameraUnavailable
            return
        }
        guard let outcome = scanOutcome else { return }
        scanOutcome = nil
        switch outcome {
        case .remembered(let food):
            amountText = ""
            selected = food
        case .unknown(let code):
            scanMessage = .unknown(code)
        case .didNotScanCleanly:
            scanMessage = .didNotScanCleanly
        }
    }

    /// The by-hand form, with the code attached and no name yet.
    private func enter(_ code: Barcode) {
        loggedNewFood = false
        sheet = .byBarcode(code)
    }

    // MARK: Search

    /// From the top: the search field (in the navigation bar's drawer, always
    /// shown), the action rows, then what the search found.
    private var searchList: some View {
        VStack(spacing: 0) {
            actionRows
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
                .accessibilityHidden(true)
            searchResults
        }
        .navigationTitle("Log Food")
        .navigationBarTitleDisplayMode(.inline)
        // At the top and always visible. Left to itself iOS 26 puts a sheet's
        // search field at the bottom, under the results it filters.
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search foods")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
        // Re-runs whenever query changes; the sleep debounces keystrokes, and
        // SwiftUI cancels the previous task automatically — a real
        // reference-DB query on every keystroke is wasted work for a search
        // field where most keystrokes are superseded within milliseconds by
        // the next one.
        .task(id: query) {
            await search()
        }
    }

    /// Ways to log a food other than picking a search result, one row each,
    /// pinned under the search field whatever the results are doing. "Scan a
    /// barcode" shows only on a phone that can scan; when the camera is not
    /// allowed it stays, and says how to allow it.
    private var actionRows: some View {
        VStack(spacing: 0) {
            if scanAvailability != .unsupported {
                actionRow("Scan a barcode", systemImage: "barcode.viewfinder",
                          hint: "Opens the camera to read a food's barcode.") {
                    startScan()
                }
            }
            actionRow("Add food by hand", systemImage: "square.and.pencil",
                      hint: "For a food that is not in the database. Macros per 100 g.") {
                addByHand()
            }
        }
        .padding(.horizontal, 16)
        .readableContentWidth()
    }

    private func actionRow(_ title: String, systemImage: String, hint: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(Theme.body)
                .foregroundStyle(Theme.accentText)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(hint)
    }

    @ViewBuilder
    private var searchResults: some View {
        if loadFailed {
            ContentUnavailableView {
                Label("Food data unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text("food.db is missing from the app bundle.")
            } actions: {
                // Without the database, by hand is the only way to log,
                // so whatever was typed comes along.
                if trimmedQuery.isEmpty {
                    LiftButton("Add food by hand") { addByHand() }
                } else {
                    LiftButton("Add \u{201C}\(trimmedQuery)\u{201D} by hand") { addByHand(named: trimmedQuery) }
                }
            }
        } else if let typedCode {
            typedCodeResults(typedCode)
        } else if !searching && results.isEmpty && trimmedQuery.count >= 2 {
            ContentUnavailableView {
                Label("No Results for \u{201C}\(trimmedQuery)\u{201D}", systemImage: "magnifyingglass")
            } description: {
                Text("Check the spelling or try a new search.")
            } actions: {
                LiftButton("Add \u{201C}\(trimmedQuery)\u{201D} by hand") { addByHand(named: trimmedQuery) }
            }
        } else {
            List {
                // The closest foods are not answers, so they say so, and the
                // food can still be added under the name that was typed.
                if !found.matchesEveryWord {
                    Text("No food has every word you typed. These are the closest.")
                        .font(Theme.detail)
                        .foregroundStyle(Theme.textSecondary)
                        .listRowSeparator(.hidden)
                }
                ForEach(results) { record in
                    Button {
                        selected = LoggableFood(record: record)
                    } label: {
                        row(record)
                    }
                    .buttonStyle(.plain)
                }
                if !found.matchesEveryWord && !results.isEmpty {
                    Button {
                        addByHand(named: trimmedQuery)
                    } label: {
                        Label("Add \u{201C}\(trimmedQuery)\u{201D} by hand", systemImage: "square.and.pencil")
                            .font(Theme.body)
                            .foregroundStyle(Theme.accentText)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
            .readableListMargins()
        }
    }

    /// A typed barcode: the remembered food as the only row, or that nothing
    /// knows it yet. Never the "Add … by hand" offer, which would name the
    /// food after its digits.
    @ViewBuilder
    private func typedCodeResults(_ typed: TypedCode) -> some View {
        switch typed {
        case .remembered(let food):
            List {
                Button {
                    amountText = ""
                    selected = food
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(food.name)
                            .font(Theme.body)
                            .foregroundStyle(Theme.textPrimary)
                        Text(LoggableFood.rememberedLine)
                            .font(Theme.detail)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .readableListMargins()
        case .unknown(let code):
            ContentUnavailableView {
                Label(code.printed, systemImage: "barcode")
                    // Digit by digit, as the form's Barcode line reads it.
                    .speechSpellsOutCharacters()
            } description: {
                Text(BarcodeLookup.notFoundMessage)
            } actions: {
                LiftButton("Enter it") { enter(code) }
            }
        }
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var results: [FoodRecord] { found.foods }

    private static let nothingFound = FoodSearchResults(foods: [], matchesEveryWord: true)

    private func addByHand(named name: String = "") {
        loggedNewFood = false
        sheet = .byHand(name: name)
    }

    private func row(_ record: FoodRecord) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(record.name)
                .font(Theme.body)
                .foregroundStyle(Theme.textPrimary)
            if let brand = record.brand, !brand.isEmpty {
                Text(brand)
                    .font(Theme.detail)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // A barcode is looked up, not searched for by name; a number that
        // fails its check digit falls through to an ordinary search. The
        // lookup waits out the same debounce as a name search, so an 8- or
        // 12-digit start of a longer code never says "doesn't know" mid-typing.
        // A different code, or none, stops showing the last one's answer now;
        // the same code (back from the amount step) is looked up at once.
        let digits = BarcodeQuery.barcodeDigits(in: query)
        let code = digits.flatMap { try? Barcode.read($0).get() }
        if code == nil || code?.normalised != typedCode?.normalised {
            typedCode = nil
        } else {
            lookUpTypedCode()
            found = Self.nothingFound
            loadFailed = false
            searching = false
            return
        }
        guard code != nil || trimmed.count >= 2 else {
            found = Self.nothingFound
            loadFailed = false
            searching = false
            return
        }

        searching = true
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }

        if code != nil {
            lookUpTypedCode()
            if typedCode != nil {
                found = Self.nothingFound
                loadFailed = false
                searching = false
                return
            }
        }

        do {
            let answer = try await ReferenceDatabase.shared.findFoods(trimmed)
            guard !Task.isCancelled else { return }
            found = answer
            loadFailed = false
        } catch {
            found = Self.nothingFound
            loadFailed = true
        }
        searching = false
    }

    // MARK: Amount entry

    private func amountEntry(for food: LoggableFood) -> some View {
        let enteredAmount = Double(amountText)
        let grams = enteredAmount.map { servingUnit.toGrams($0) }
        let preview = grams.map { food.nutrition(grams: $0) }

        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(food.name)
                        .font(Theme.cardTitle)
                        .foregroundStyle(Theme.accentText)
                    if let brand = food.brand, !brand.isEmpty {
                        Text(brand)
                            .font(Theme.detail)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    if let code = food.rememberedCode {
                        rememberedLines(code: code)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Amount")
                        .font(Theme.sectionLabel)
                        .foregroundStyle(Theme.accentText)

                    HStack {
                        TextField("0", text: $amountText)
                            .keyboardType(.decimalPad)
                            .font(Theme.body)
                            .foregroundStyle(Theme.textPrimary)
                        Text(servingUnit.abbreviation)
                            .font(Theme.body)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(Theme.cardPadding)
                    .background(Theme.background, in: .rect(cornerRadius: Theme.chipRadius))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.cardPadding)
                .liftCardBackground()

                if let preview {
                    previewCard(preview)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .readableContentWidth()
        }
        .liftScreen()
        .keyboardDoneButton()
        .background(Theme.background)
        .navigationTitle("Log Food")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Back") { backToSearch() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Log") { log(food) }
                    .disabled(!(enteredAmount.map { $0 > 0 } ?? false))
            }
        }
    }

    /// What a remembered food adds under its name: that the figures are the
    /// person's own, and the two things they can do about it.
    private func rememberedLines(code: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LoggableFood.rememberedLine)
                .font(Theme.detail)
                .foregroundStyle(Theme.textSecondary)
            LiftButton("Edit", isGhost: true) { sheet = .remembered(code: code) }
                .accessibilityLabel(RememberedFoodWords.editTitle)
            Button(RememberedFoodWords.forgetButton, role: .destructive) {
                confirmingForget = true
            }
            .font(Theme.body)
            .frame(minHeight: 44)
            .forgetBarcodeConfirmation(isPresented: $confirmingForget) {
                RememberedFoods.forget(code: code, in: context)
                backToSearch()
            }
        }
        .padding(.top, 4)
    }

    /// After the editor saved: show what is now remembered, or go back to
    /// search if it was forgotten from inside the editor.
    private func refreshSelected(code: String) {
        if let food = RememberedFoods.find(code: code, in: context) {
            selected = LoggableFood(remembered: food)
            lookUpTypedCode()
        } else {
            backToSearch()
        }
    }

    private func backToSearch() {
        selected = nil
        amountText = ""
        // An Edit or a Forget may have changed what the typed code finds.
        lookUpTypedCode()
    }

    private func lookUpTypedCode() {
        guard let digits = BarcodeQuery.barcodeDigits(in: query) else {
            typedCode = nil
            return
        }
        switch BarcodeLookup.look(up: digits, symbology: nil, in: context) {
        case .remembered(let food): typedCode = .remembered(food)
        case .unknown(let code): typedCode = .unknown(code)
        case .didNotScanCleanly: typedCode = nil
        }
    }

    private func previewCard(_ nutrition: NutritionFacts) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(Int(nutrition.calories)) kcal")
                .font(Theme.figure)
                .foregroundStyle(Theme.textPrimary)
            HStack(spacing: 10) {
                Text("P \(Int(nutrition.proteinG))")
                Text("C \(Int(nutrition.carbsG))")
                Text("F \(Int(nutrition.fatG))")
                if let fiber = nutrition.fiberG {
                    Text("Fib \(Int(fiber))")
                }
            }
            .font(Theme.detail)
            .foregroundStyle(Theme.textSecondary)
            // Saturated fat, sugar and sodium when the database has them —
            // `FoodRecord.nutrition(grams:)` fills all three, and the entry
            // logged below snapshots them with the rest.
            if let details = NutrientDetailsDisplay.entryLine(nutrition) {
                Text(details)
                    .font(Theme.detail)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.cardPadding)
        .liftCardBackground()
    }

    private func log(_ food: LoggableFood) {
        guard let enteredAmount = Double(amountText), enteredAmount > 0 else { return }
        let grams = servingUnit.toGrams(enteredAmount)
        let entry = FoodEntry(
            foodRefID: food.id,
            name: food.name,
            brand: food.brand,
            quantity: enteredAmount,
            servingUnit: servingUnit.abbreviation,
            amountGrams: grams,
            nutrition: food.nutrition(grams: grams),
            mealType: mealType
        )
        context.insert(entry)
        try? context.save()
        WidgetCenter.shared.reloadAllTimelines()
        WatchSyncReceiver.shared?.pushRecentFoodsSnapshot()
        onLogged()
        dismiss()
    }
}
