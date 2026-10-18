import AppKit
import SwiftUI

/// Showing this Mac on a TV is AirPlay (R38): macOS's own Screen Mirroring (sound, and "Use As Separate Display"),
/// received on the TV. Apps can't open Control Center's Screen Mirroring, so Janus opens Displays settings, whose
/// + menu lists AirPlay TVs under "Mirror or extend to".
enum AirPlayMirroring {
    static func openDisplaySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
    }
}

/// The TV's Overview, beside the TV itself: mirror or extend this Mac to it.
struct ScreenShareCard: View {
    let device: Device

    var body: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 52, height: 52)
                .background(Circle().fill(.quaternary))
            VStack(spacing: 4) {
                Text("Screen Mirroring").font(.headline)
                Text("Choose “\(device.name)” in Control Center → Screen Mirroring while Janus runs on the TV.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Button("Open Display Settings") { AirPlayMirroring.openDisplaySettings() }
                .controlSize(.large)
                .help("Click + in Displays to mirror or extend to the TV")
            Spacer(minLength: 0)
        }
        .padding(Metrics.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cardBackground()
    }
}
