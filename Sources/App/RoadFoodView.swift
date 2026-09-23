import SwiftUI
import SwiftData
import WidgetKit
import LiftCore

/// Road Food, reached from Food: pick where you are stopping, see what there
/// fits what is left of today, and log it in one tap.
///
/// The rules -- what fits, the 10% band, the order, how old is too old, the
/// entry a row logs -- are `RoadFoodRanking`, where they are tested. This is
/// the screen. It is a port of LIFT web's Road Food (`lift/app.js`,
/// `renderRoad`), words included, so the two read the same.
///
/// **No location, of any kind.** You pick the chain; LIFT never asks where you
/// are, so there is no new permission and nothing new in the privacy manifest.
/// The recently used chains are kept on this device only, in `@AppStorage`,
/// and deliberately not in the backup -- a convenience about this screen, not
/// a record.
struct RoadFoodView: View {
    let catalog: RoadFoodCatalog
    let source: RoadFoodSource

    @Environment(\.dismiss) private var dismiss
    @AppStorage("roadFoodRecent") private var recentRaw = ""
    /// A coach's picks, if a plan brought any. Read through `@AppStorage` so
    /// clearing them here, or a new plan arriving, redraws this screen.
    @AppStorage(RoadPicks.storageKey) private var picksData = Data()
    @State private var path: [RoadFoodPlace] = []

    private var picks: RoadPicks? { RoadPicks.decode(picksData) }
    private var pickIDs: [String] { picks?.ids ?? [] }

    /// Every item in the file, for counting what is picked across all of it.
    private var everything: [RoadFoodItem] {
        catalog.chains.flatMap(\.items) + catalog.snacks
    }

    var body: some View {
        NavigationStack(path: $path) {
            RoadFoodPage { contentWidth in
                picker(contentWidth: contentWidth)
            }
            .navigationTitle("Road Food")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: RoadFoodPlace.self) { place in
                RoadFoodPlaceView(catalog: catalog, source: source, place: place)
            }
        }
    }

    private func picker(contentWidth: CGFloat) -> some View {
        let columns = AdaptiveLayout.columns(for: contentWidth, minWidth: 240, maxColumns: 3)
        let ordered = RoadFoodRanking.orderChains(catalog.chains,
                                                  recent: RoadFoodRanking.decodeRecent(recentRaw))
        return VStack(alignment: .leading, spacing: Theme.cardSpacing) {
            Text("Pick where you are stopping. The list is ranked against what is left of today, "
                 + "and works with no signal.")
                .font(Theme.body)
                .foregroundStyle(Theme.textSecondary)

            if source == .developmentSample { RoadFoodSampleNotice() }

            picksCard

            if !catalog.snacks.isEmpty {
                AdaptiveGrid(columns: columns) {
                    placeTile(title: "Gas station",
                              detail: appendingPicked(
                                to: catalog.snackCategories.map(RoadFoodRanking.categoryLabel)
                                    .joined(separator: ", "),
                                count: RoadFoodRanking.pickCount(catalog.snacks, ids: pickIDs)),
                              place: .gasStation)
                }
            }

            if !ordered.recent.isEmpty {
                sectionTitle("Recent")
                AdaptiveGrid(columns: columns) {
                    ForEach(ordered.recent) { chainTile($0) }
                }
            }
            if !ordered.rest.isEmpty {
                sectionTitle(ordered.recent.isEmpty ? "Chains" : "All chains")
                AdaptiveGrid(columns: columns) {
                    ForEach(ordered.rest) { chainTile($0) }
                }
            }

            Text("Numbers come from each chain's own published nutrition, checked by hand, and each "
                 + "place shows the date they were checked. LIFT never asks where you are.")
                .font(Theme.detail)
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 4)
        }
    }

    /// What a coach marked, when a plan brought any. Only what this copy of
    /// the file still has is counted -- an id it does not know is skipped, so
    /// this card can be absent even while picks are stored, and then nothing
    /// is drawn rather than a card promising rows nobody can see.
    @ViewBuilder
    private var picksCard: some View {
        let total = RoadFoodRanking.pickCount(everything, ids: pickIDs)
        if total > 0 {
            let places = catalog.chains.filter { RoadFoodRanking.pickCount($0.items, ids: pickIDs) > 0 }
                .count + (RoadFoodRanking.pickCount(catalog.snacks, ids: pickIDs) > 0 ? 1 : 0)
            LiftCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text(RoadPicks.label("picks", from: picks))
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("\(total) \(total == 1 ? "item" : "items") at \(places) "
                         + "\(places == 1 ? "place" : "places"), at the top of those lists. "
                         + "The ranking underneath them is unchanged.")
                        .font(Theme.detail)
                        .foregroundStyle(Theme.textSecondary)
                    // Clearing is this phone's own action: a plan that carries
                    // no picks says nothing about them rather than retracting
                    // them, so nothing a coach sends can take them back.
                    Button("Clear these picks") { picksData = Data() }
                        .font(Theme.body.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .buttonStyle(.plain)
                }
            }
        }
    }

    /// "22 items · 3 picked for you", web's own wording and order.
    private func appendingPicked(to detail: String, count: Int) -> String {
        guard count > 0 else { return detail }
        return detail.isEmpty ? "\(count) picked for you" : "\(detail) · \(count) picked for you"
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(Theme.cardTitle)
            .foregroundStyle(Theme.accent)
            .padding(.top, 6)
    }

    private func chainTile(_ chain: RoadFoodChain) -> some View {
        let count = chain.items.count
        var detail = appendingPicked(to: "\(count) \(count == 1 ? "item" : "items")",
                                     count: RoadFoodRanking.pickCount(chain.items, ids: pickIDs))
        if let date = RoadFoodRanking.dateText(chain.checkedOn) { detail += " · checked \(date)" }
        return placeTile(title: chain.name, detail: detail, place: .chain(chain.id))
    }

    private func placeTile(title: String, detail: String, place: RoadFoodPlace) -> some View {
        Button {
            if case .chain(let id) = place {
                recentRaw = RoadFoodRanking.encodeRecent(
                    RoadFoodRanking.remember(RoadFoodRanking.decodeRecent(recentRaw), id: id))
            }
            path.append(place)
        } label: {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.leading)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(Theme.detail)
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(Theme.cardPadding)
            .contentShape(Rectangle())
            .liftCardBackground()
        }
        .buttonStyle(.plain)
    }
}

/// A chain, or the gas station's snacks.
enum RoadFoodPlace: Hashable {
    case chain(String)
    case gasStation
}

/// A scrolling page in the Road Food sheet, handing its content the width it
/// has. A sheet is not a tab, so `\.pageWidth` from `RootView` does not
/// describe it; this measures the sheet itself and feeds the same
/// `AdaptiveLayout` rules.
private struct RoadFoodPage<Content: View>: View {
    @ViewBuilder let content: (CGFloat) -> Content

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content(AdaptiveLayout.contentWidth(forPage: proxy.size.width))
                    .padding(.horizontal, AdaptiveLayout.pageGutter)
                    .padding(.top, 12)
                    .padding(.bottom, 40)
                    .adaptivePageWidth()
            }
        }
        .liftScreen()
        .background(Theme.background)
    }
}

/// Said on every Road Food screen of a development build that is showing the
/// made-up sample rather than the curated file. A release build never has it.
private struct RoadFoodSampleNotice: View {
    var body: some View {
        Text("Development sample: made-up places and numbers. The curated list replaces them "
             + "once Resources/road-food.json is in the app.")
            .font(Theme.detail)
            .foregroundStyle(Theme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .liftCardBackground()
    }
}

// MARK: - A chain or the gas station

struct RoadFoodPlaceView: View {
    let catalog: RoadFoodCatalog
    let source: RoadFoodSource
    let place: RoadFoodPlace

    @Environment(\.modelContext) private var context
    @Query private var todaysFood: [FoodEntry]

    @AppStorage("goalCalories") private var goalCalories = 1748.0
    @AppStorage("goalProtein") private var goalProtein = 160.0
    @AppStorage("goalIsSet") private var goalIsSet = false
    @AppStorage(RoadPicks.storageKey) private var picksData = Data()

    @State private var meal = MealType.forHour(Calendar.current.component(.hour, from: .now))
    @State private var category: String?
    @State private var note: String?

    init(catalog: RoadFoodCatalog, source: RoadFoodSource, place: RoadFoodPlace) {
        self.catalog = catalog
        self.source = source
        self.place = place
        let key = DayKey.today
        _todaysFood = Query(filter: #Predicate<FoodEntry> { $0.dayKey == key })
    }

    private var chain: RoadFoodChain? {
        guard case .chain(let id) = place else { return nil }
        return catalog.chains.first { $0.id == id }
    }

    private var isGasStation: Bool { place == .gasStation }

    private var items: [RoadFoodItem] {
        if let chain { return chain.items }
        return catalog.snacks.filter { category == nil || $0.category == category }
    }

    /// Home's number, from the same type Home reads it from.
    private var remaining: RemainingMacros? {
        RemainingMacros.forDay(goalIsSet: goalIsSet, goalCalories: goalCalories,
                               goalProteinG: goalProtein, eaten: todaysFood.totalNutrition)
    }

    /// When the numbers were checked. A gas-station view mixes products, so
    /// it shows the oldest date among what is on screen.
    private var checkedOn: String? {
        if let chain { return chain.checkedOn }
        return items.compactMap(\.checkedOn).filter { CalendarDay($0) != nil }.min()
    }

    private var rules: [String] {
        if let chain { return RoadFoodRanking.rulesFor(catalog.rules, kind: chain.kind) }
        return RoadFoodRanking.gasStationRules(catalog.rules)
    }

    var body: some View {
        // Ranked against the whole number the fits line shows, so an item at
        // exactly "640 kcal" fits a screen that says 640 are left.
        let remaining = remaining
        // Ranked first, then the coach's picks floated to the top of each
        // group. Nothing about the ranking changes: the same items fit, in the
        // same order among themselves, and the same ones are left out.
        let picks = RoadPicks.decode(picksData)
        let ranked = RoadFoodRanking.withPicks(
            RoadFoodRanking.rank(items, remainingCalories: remaining.map { Double($0.wholeCalories) }),
            ids: picks?.ids ?? [])

        RoadFoodPage { contentWidth in
            VStack(alignment: .leading, spacing: Theme.cardSpacing) {
                header

                if source == .developmentSample { RoadFoodSampleNotice() }

                if isGasStation, catalog.snackCategories.count > 1 { categoryChips }

                fitCard(remaining: remaining, ranked: ranked, picks: picks)

                AdaptiveColumns(columns: AdaptiveLayout.columns(for: contentWidth, minWidth: 340)) {
                    VStack(alignment: .leading, spacing: Theme.cardSpacing) {
                        mealPicker
                        if !ranked.fits.isEmpty { itemCard(ranked.fits, ranked: ranked, picks: picks) }
                        if !ranked.over.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("A little over")
                                    .font(Theme.cardTitle)
                                    .foregroundStyle(Theme.accent)
                                Text("Within 10% of what is left.")
                                    .font(Theme.detail)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            .padding(.top, 6)
                            // A pick that is over stays over: the pick is
                            // about the food, and what is left of the day is
                            // your own arithmetic.
                            itemCard(ranked.over, ranked: ranked, picks: picks)
                        }
                    }
                    if !rules.isEmpty { rulesCard }
                }
            }
        }
        // Pinned to the bottom rather than placed in the page, so it is seen
        // wherever the row that was logged had been scrolled to.
        .safeAreaInset(edge: .bottom) {
            if let note {
                Text(note)
                    .font(Theme.body)
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: AdaptiveLayout.readableWidth, alignment: .leading)
                    .padding(Theme.cardPadding)
                    .liftCardBackground()
                    .padding(.horizontal, AdaptiveLayout.pageGutter)
                    .padding(.bottom, 8)
                    .onTapGesture { self.note = nil }
                    .accessibilityAddTraits(.isStaticText)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: note)
        .navigationTitle(chain?.name ?? "Gas station")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(chain?.name ?? "Gas station")
                .font(Theme.figure)
                .foregroundStyle(Theme.textPrimary)

            HStack(spacing: 4) {
                if let date = RoadFoodRanking.dateText(checkedOn) {
                    Text("Checked on \(date)")
                } else {
                    Text("No check date on file for these numbers.")
                }
                if let link = chain?.source, link.hasPrefix("https://"), let url = URL(string: link) {
                    Text("·")
                    Link("source", destination: url)
                        .foregroundStyle(Theme.accent)
                }
            }
            .font(Theme.detail)
            .foregroundStyle(Theme.textSecondary)

            if RoadFoodRanking.isStale(checkedOn: checkedOn, today: DayKey.today) == true {
                Text("These numbers are more than six months old. Menus change, so check them "
                     + "against the board before you count on them.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.textPrimary)
            }
        }
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                LiftChip(label: "All", isSelected: category == nil) { category = nil }
                ForEach(catalog.snackCategories, id: \.self) { c in
                    LiftChip(label: RoadFoodRanking.categoryLabel(c), isSelected: category == c) {
                        category = c
                    }
                }
            }
        }
    }

    // MARK: The fits line

    private func fitCard(remaining: RemainingMacros?, ranked: RoadFoodRanking.Ranked,
                         picks: RoadPicks?) -> some View {
        LiftCard {
            VStack(alignment: .leading, spacing: 6) {
                if let remaining {
                    let kcal = max(0, remaining.wholeCalories)
                    let protein = remaining.wholeProteinG > 0
                        ? " · \(remaining.wholeProteinG) g protein"
                        : " · protein goal met"
                    // Verbatim, so "1502" reads as Home and the logged note
                    // write it, not as a localized "1,502" beside them.
                    Text(verbatim: "Fits your remaining \(kcal) kcal\(protein)")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Most protein per 100 kcal first; lower sodium breaks a tie. Anything more "
                         + "than 10% over what is left is not shown.")
                        .font(Theme.detail)
                        .foregroundStyle(Theme.textSecondary)
                    if ranked.fits.isEmpty && ranked.over.isEmpty {
                        Text(remaining.calories <= 0
                             ? "Today's calories are used, so nothing here fits what is left."
                             : "Nothing here fits what is left today.")
                            .font(Theme.body)
                            .foregroundStyle(Theme.textPrimary)
                    }
                } else {
                    Text("No goal set")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("So this is ranked by protein per 100 kcal alone, with nothing left out. "
                         + "Set a goal on Home and it will rank against what is left of your day.")
                        .font(Theme.detail)
                        .foregroundStyle(Theme.textSecondary)
                }
                // One line, whether or not there is a goal. Said, never
                // scored: nothing here or anywhere judges what was eaten
                // against what a coach marked.
                if !ranked.picked.isEmpty {
                    Text("\(RoadPicks.label("picks", from: picks)) are first, marked. "
                         + "Nothing else is moved, and nothing that fits is hidden.")
                        .font(Theme.detail)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    // MARK: Ordering rules

    /// Right after a menu changes, when the numbers are not.
    private var rulesCard: some View {
        LiftCard(title: "Ordering") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rules, id: \.self) { rule in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(Theme.accent)
                        Text(rule)
                            .font(Theme.body)
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: Meal

    private var mealPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Log to")
                .font(Theme.sectionLabel)
                .foregroundStyle(Theme.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(MealType.allCases) { m in
                        LiftChip(label: m.displayName, isSelected: meal == m) { meal = m }
                    }
                }
            }
        }
    }

    // MARK: Items

    private func itemCard(_ list: [RoadFoodItem], ranked: RoadFoodRanking.Ranked,
                          picks: RoadPicks?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(list.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                }
                row(item, isPick: ranked.isPicked(item), picks: picks)
                    .padding(.vertical, 12)
            }
        }
        .padding(.horizontal, Theme.cardPadding)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liftCardBackground()
    }

    private func row(_ item: RoadFoodItem, isPick: Bool, picks: RoadPicks?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                // Said in words, above the name, in weight rather than
                // colour: this is a label on what a coach marked, not a
                // verdict on the food. Nothing at all on the rest.
                if isPick {
                    Text(RoadPicks.label("pick", from: picks).uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .kerning(0.5)
                        .foregroundStyle(Theme.textSecondary)
                }
                Text(item.displayName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(macroLine(item))
                    .font(Theme.detail)
                    .foregroundStyle(Theme.textSecondary)
                if let about = aboutLine(item) {
                    Text(about).font(Theme.detail).foregroundStyle(Theme.textSecondary)
                }
                // Shown, never targeted: plain text, no colour, no threshold.
                if let details = NutrientDetailsDisplay.entryLine(
                    NutritionFacts(sugarG: item.sugarG, sodiumMg: item.sodiumMg,
                                   saturatedFatG: item.saturatedFatG)) {
                    Text(details).font(Theme.detail).foregroundStyle(Theme.textSecondary)
                }
                if let modification = item.modification {
                    Text(modification).font(Theme.detail).foregroundStyle(Theme.textSecondary)
                }
                if let barcode = item.barcode {
                    Text("Barcode \(barcode)").font(Theme.detail).foregroundStyle(Theme.textSecondary)
                }
                if let reason = RoadFoodRanking.cannotLogReason(item) {
                    Text(reason).font(Theme.detail).foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if RoadFoodRanking.cannotLogReason(item) == nil {
                Button { log(item) } label: {
                    Text("Log it")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Theme.accent))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Log \(item.displayName)")
            }
        }
    }

    /// "370 kcal - P 34 - F 10 - C 37 - Fib 2", Food's own macro line, with
    /// what is not listed said in words rather than drawn as a zero.
    private func macroLine(_ item: RoadFoodItem) -> String {
        var parts = [item.kcal.map { "\(Int($0.rounded())) kcal" } ?? "kcal not listed",
                     item.proteinG.map { "P \(Int($0.rounded()))" } ?? "protein not listed"]
        if let fat = item.fatG { parts.append("F \(Int(fat.rounded()))") }
        if let carbs = item.carbsG { parts.append("C \(Int(carbs.rounded()))") }
        if let fiber = item.fiberG { parts.append("Fib \(Int(fiber.rounded()))") }
        return parts.joined(separator: " - ")
    }

    /// "9.2 g protein per 100 kcal · 1 sandwich".
    private func aboutLine(_ item: RoadFoodItem) -> String? {
        var parts: [String] = []
        if let density = RoadFoodRanking.proteinPer100(item), density.isFinite, (item.kcal ?? 0) > 0 {
            parts.append("\(density.formatted(.number.precision(.fractionLength(0...1)))) g protein per 100 kcal")
        }
        if let serving = item.serving { parts.append(serving) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Log it

    private func log(_ item: RoadFoodItem) {
        guard let entry = RoadFoodRanking.entry(for: item, chainName: chain?.name, mealType: meal) else { return }
        let before = todaysFood.totalNutrition
        context.insert(entry)
        try? context.save()
        WidgetCenter.shared.reloadAllTimelines()
        WatchSyncReceiver.shared?.pushRecentFoodsSnapshot()

        var text = "Logged \(item.displayName) to \(meal.displayName)."
        if let left = RemainingMacros.forDay(goalIsSet: goalIsSet, goalCalories: goalCalories,
                                             goalProteinG: goalProtein, eaten: before + entry.nutrition) {
            text += " \(left.calorieHeadline) today."
        }
        note = text
    }
}

extension View {
    /// A page-sized sheet on iPad from iOS 18, so a chain's list and its
    /// ordering tips can sit side by side when the window has the room. The
    /// phone's sheet is unchanged, and iOS 17 keeps the system's form sheet.
    @ViewBuilder
    func roadFoodSheetSizing() -> some View {
        if #available(iOS 18.0, *) {
            presentationSizing(.page)
        } else {
            self
        }
    }
}
