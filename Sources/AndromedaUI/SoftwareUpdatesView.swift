import Sparkle
import SwiftUI

enum ReleaseChannel: String {
    case privateBeta = "private-beta"
    case publicBeta = "public-beta"
    case publicRelease = "public-release"
    case development

    var label: String {
        switch self {
        case .privateBeta: "Private Beta"
        case .publicBeta: "Public Beta"
        case .publicRelease: "Public Release"
        case .development: "Development Build"
        }
    }

    static func installed(in info: [String: Any]) -> Self? {
        if let value = info["AndromedaReleaseChannel"] as? String {
            return Self(rawValue: value)
        }
        return info["CFBundleVersion"] == nil ? .development : nil
    }
}

struct SoftwareUpdatesView: View {
    let updater: SPUUpdater?
    var showVersionHistory: (() -> Void)?
    var receivesPublicBetas: Binding<Bool>?
    @State private var historyLinkHovered = false

    var body: some View {
        let info = Bundle.main.infoDictionary ?? [:]
        let channel = ReleaseChannel.installed(in: info)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeading(title: "Software Updates", symbol: "arrow.trianglehead.clockwise", tint: .blue)
                Spacer()
                if let showVersionHistory {
                    Link(destination: URL(string: "andromeda:release-history")!) {
                        Text("What’s New")
                            .font(.callout)
                            .underline(!historyLinkHovered)
                            .foregroundStyle(.blue)
                    }
                    .environment(\.openURL, OpenURLAction { _ in
                        showVersionHistory()
                        return .handled
                    })
                    .onHover { historyLinkHovered = $0 }
                }
            }
            if let version = info["CFBundleShortVersionString"] as? String {
                Text("Installed version \(version)").font(.callout)
            }
            LabeledContent("Release channel", value: channel?.label ?? "Unspecified")
                .font(.callout)
            if let updater {
                ConfiguredUpdateControls(updater: updater, receivesPublicBetas: receivesPublicBetas)
            } else {
                Text("Update checks are unavailable in this build. Install a newer version from its disk image.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .card()
    }
}

private struct ConfiguredUpdateControls: View {
    let updater: SPUUpdater
    let receivesPublicBetas: Binding<Bool>?
    @State private var canCheck = false
    @State private var automaticallyChecks = false
    @State private var lastChecked: Date?
    @State private var sessionInProgress = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let receivesPublicBetas {
                Toggle("Receive public beta updates", isOn: receivesPublicBetas)
                    .disabled(sessionInProgress)
                Text("Public betas arrive sooner and may have unfinished features. Turning this off switches future checks to public releases. The installed version stays until a newer public release is available.")
                    .font(.callout).foregroundStyle(.secondary)
            }
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
        .onReceive(updater.publisher(for: \.sessionInProgress)) { sessionInProgress = $0 }
    }
}
