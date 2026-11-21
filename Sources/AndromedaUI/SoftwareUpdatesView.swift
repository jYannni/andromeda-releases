import Sparkle
import SwiftUI

struct SoftwareUpdatesView: View {
    let updater: SPUUpdater?
    var showVersionHistory: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: "Software Updates", symbol: "arrow.trianglehead.clockwise", tint: .blue)
            if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                Text("Installed version \(version)").font(.callout)
            }
            if let updater {
                ConfiguredUpdateControls(updater: updater)
            } else {
                Text("Update checks are unavailable in this build. Install the next beta from its disk image.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let showVersionHistory {
                Button("What’s New…", action: showVersionHistory)
            }
        }
        .card()
    }
}

private struct ConfiguredUpdateControls: View {
    let updater: SPUUpdater
    @State private var canCheck = false
    @State private var automaticallyChecks = false
    @State private var lastChecked: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Automatically check for updates", isOn: Binding(
                get: { automaticallyChecks },
                set: { updater.automaticallyChecksForUpdates = $0 }
            ))
            Text("Andromeda contacts its update server when you check. When an update is available, you can read what changed before deciding whether to install it.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!canCheck)
                if let lastChecked {
                    Text("Last checked \(lastChecked.formatted(date: .abbreviated, time: .shortened))")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .onReceive(updater.publisher(for: \.canCheckForUpdates)) {
            canCheck = $0
            lastChecked = updater.lastUpdateCheckDate
        }
        .onReceive(updater.publisher(for: \.automaticallyChecksForUpdates)) { automaticallyChecks = $0 }
    }
}
