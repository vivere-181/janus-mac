import SwiftUI

/// Guided pairing: nearby devices appear live; the same key shows on both screens; IP fallback.
struct AddDeviceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var addressNote: String?
    @State private var pairingID: String?
    @State private var knownPaired: Set<String> = []

    private var justPaired: Device? {
        model.pairedDevices.first { !knownPaired.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                IconTile(symbol: "plus", color: .green, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add a Device").font(.title2.weight(.semibold))
                    Text("Pair a phone or tablet with this Mac.").foregroundStyle(.secondary)
                }
            }

            if let device = justPaired {
                success(device)
            } else {
                steps
                nearby
                manual
            }

            HStack {
                Spacer()
                Button(justPaired == nil ? "Cancel" : "Done") { dismiss() }
                    .keyboardShortcut(justPaired == nil ? .cancelAction : .defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500)
        .onAppear { knownPaired = Set(model.pairedDevices.map(\.id)) }
        .task {
            // Keep announcing this Mac while the sheet is open so nearby phones show up quickly.
            while !Task.isCancelled {
                model.refreshNetwork()
                await model.refreshDevices()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 8) {
            step(1, "Connect the phone to the same Wi-Fi as this Mac.")
            step(2, "Open the companion app on the phone.")
            step(3, "Choose “\(model.announcedName.isEmpty ? "this Mac" : model.announcedName)” on the phone, or pick the phone below.")
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)")
                .font(.caption.weight(.bold)).foregroundStyle(Color.janusOn)
                .frame(width: 20, height: 20)
                .background(Color.janus, in: Circle())
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var nearby: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Nearby Devices").font(.headline)
                ProgressView().controlSize(.small)
            }
            let candidates = model.devices.filter { !$0.isPaired && ($0.isReachable || $0.isPairRequestedByPeer) }
            if candidates.isEmpty {
                Text("Searching… Devices appear here as soon as the companion app is open on the same network.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            } else {
                ForEach(candidates) { d in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Image(systemName: d.symbol).font(.title2).frame(width: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(d.name).font(.body.weight(.medium))
                                Text(d.addresses.first ?? d.type.capitalized).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if d.isPairRequestedByPeer {
                                Button("Decline") { d.rejectPairing() }
                                Button("Pair") { d.acceptPairing() }.buttonStyle(.borderedProminent)
                            } else if d.isPairRequested {
                                ProgressView().controlSize(.small)
                                Button("Cancel") { d.rejectPairing() }
                            } else {
                                Button("Pair") { pairingID = d.id; d.requestPairing() }.buttonStyle(.borderedProminent)
                            }
                        }
                        if d.isPairRequested || d.isPairRequestedByPeer {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.shield").foregroundStyle(.secondary)
                                Text(d.isPairRequested ? "Accept on the phone. Make sure it shows the code" : "Make sure the phone shows the code")
                                Text(d.verificationKey).monospaced().bold()
                            }
                            .font(.callout)
                        }
                    }
                    .padding(12)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    private var manual: some View {
        DisclosureGroup("Can't find it? Add by IP address") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("e.g. \(AppModel.exampleAddress)", text: $address)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addAddress)
                    Button("Add", action: addAddress).disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text(addressNote ?? "The phone's IP address is in its Wi-Fi settings (tap the network it's on) or under Settings → About phone → Status. This Mac will keep connecting to it directly.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
        }
    }

    private func addAddress() {
        if model.addAddress(address) {
            addressNote = "Looking for a device at \(address)… It will appear above within a few seconds."
            address = ""
        } else {
            addressNote = "That doesn't look like an IP address."
        }
    }

    private func success(_ device: Device) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 48)).foregroundStyle(.green)
            Text("Paired with \(device.name)").font(.title3.weight(.semibold))
            Text("It's now available in the sidebar and the menu bar.").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .onAppear { model.selectedDeviceID = device.id }
    }
}

struct RenameDeviceSheet: View {
    let device: Device
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename \(device.name)").font(.title3.weight(.semibold))
            TextField("Name", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            Text("This name is used on this Mac only. The phone calls itself “\(device.announcedName)”; to change that, rename it in the companion app on the phone.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if device.hasNickname {
                    Button("Use Phone's Name") { device.rename(nil); dismiss() }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { text = device.name }
    }

    private func save() {
        device.rename(text)
        dismiss()
    }
}

/// "Remove device" confirmation, shared by the sidebar menu and Settings.
struct RemoveDeviceConfirmation: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var device: Device?

    func body(content: Content) -> some View {
        content.confirmationDialog("Remove \(device?.name ?? "device")?",
                                   isPresented: Binding(get: { device != nil }, set: { if !$0 { device = nil } }),
                                   presenting: device) { d in
            Button("Remove", role: .destructive) { model.removeDevice(d) }
        } message: { d in
            Text("\(d.name) will be unpaired from this Mac and stop syncing. To use it again, add it as a new device.")
        }
    }
}

extension View {
    func removeDeviceConfirmation(_ device: Binding<Device?>) -> some View {
        modifier(RemoveDeviceConfirmation(device: device))
    }
}
