import SwiftUI
import LiftCore

/// Settings → Training → My equipment: a switch per kind of equipment.
struct MyEquipmentView: View {
    @State private var notOwned = MyEquipment.load()

    var body: some View {
        List {
            Section {
                ForEach(MyEquipment.kinds) { kind in
                    Toggle(kind.displayName, isOn: Binding(
                        get: { !notOwned.contains(kind.id) },
                        set: { owned in
                            if owned { notOwned.remove(kind.id) } else { notOwned.insert(kind.id) }
                            MyEquipment.save(notOwned)
                        }))
                }
            } footer: {
                Text("Exercise search shows what you can do with what's switched on, and says how many it left out. An exercise with no equipment listed always shows.")
            }

            if !notOwned.isEmpty {
                Section {
                    Button("I have all of it") {
                        notOwned = []
                        MyEquipment.save(notOwned)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("My equipment")
        .navigationBarTitleDisplayMode(.inline)
    }
}
