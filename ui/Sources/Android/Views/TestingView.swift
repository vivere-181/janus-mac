import SwiftUI

/// Testing aid (temporary): every kind of notification and card on demand, and the raw data the phones send.
/// Simulated notifications come from a pretend "Test Phone", so their buttons go nowhere.
struct TestingPane: View {
    @Environment(AppModel.self) private var model
    private static let sections = ["Notifications", "Calls", "Calendar", "Live Activities", "Other Cards"]

    var body: some View {
        let available = Simulator.available
        Form {
            Section {
                Text("Shows each kind of notification and card as it would appear, so you can check how it looks and what it does. Simulated notifications come from a pretend “Test Phone”: their buttons don't reach a real phone. Live activities and calendar events appear next to the real ones until you clear them.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !available {
                    Label("Pair a phone first: simulations use its connection.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            ForEach(Self.sections, id: \.self) { section in
                Section(section) {
                    ForEach(Simulator.Item.allCases.filter { $0.section == section }) { item in
                        row(item, enabled: available)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .contentMargins(.horizontal, 0, for: .scrollContent)
        .navigationTitle("Testing")
        .navigationSubtitle("Simulated notifications and raw phone data")
        .toolbar {
            ToolbarItemGroup {
                Button { Simulator.clear() } label: { Label("Clear Simulated", systemImage: "eraser") }
                    .help("Remove everything simulated (cards, live activities, the pretend call and meeting)")
                Button { Inspector.shared.show() } label: { Label("Inspector", systemImage: "list.bullet.rectangle") }
                    .help("The raw data behind notifications, live activities, calls, calendar and device profiles")
            }
        }
    }

    private func row(_ item: Simulator.Item, enabled: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(item.tint.gradient, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                Text(item.detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Show") { Simulator.run(item) }
                .disabled(!enabled)
        }
    }
}
