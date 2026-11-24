import AndromedaAppModel
import AndromedaCore
import Charts
import SwiftUI

struct StoragePanelView: View {
    let model: AppModel
    let openApp: () -> Void
    let openTrends: () -> Void
    let openTools: () -> Void
    let openSettings: () -> Void

    @State private var storage: ConnectedStorage?
    @State private var refresh = 0
    private let storageTint = Color(light: 0x3067B4, dark: 0x97BEFF)
    private let spacePlanTint = Color(light: 0x307B72, dark: 0x76CBBE)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                AppIconView(size: 26)
                Wordmark(size: 17)
                Spacer()
                Button { refresh += 1 } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Refresh storage")
                .help("Refresh storage")
            }
            totalCard
            startupCard
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                tile("Connected Volumes", symbol: "externaldrive", tint: storageTint) {
                    Text(storage.map { $0.mountedVolumeCount.formatted() } ?? "—")
                        .font(.headline).monospacedDigit()
                }
                Button(action: openTools) {
                    tile("Tools", symbol: "wrench.and.screwdriver", tint: spacePlanTint) {
                        Label("Open tools", systemImage: "arrow.up.right")
                            .labelStyle(.titleAndIcon).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            Divider()
            HStack(spacing: 8) {
                Button("Open Andromeda", action: openApp)
                    .buttonStyle(.borderedProminent)
                Spacer()
                Button("Storage Trends", systemImage: "chart.xyaxis.line", action: openTrends)
                    .help("Open Storage Trends")
                Button("Settings", systemImage: "gearshape", action: openSettings)
                    .help("Open Andromeda Settings")
            }
            .controlSize(.regular)
            .labelStyle(.iconOnly)
        }
        .padding(16)
        .background(Palette.canvas)
        .clipShape(.rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Palette.hairline))
        .task(id: refresh) {
            repeat {
                let reading = try? await BackgroundWork.run("Andromeda Menu Bar Storage", ConnectedStorage.current)
                guard !Task.isCancelled else { return }
                storage = reading
                try? await Task.sleep(for: .seconds(20))
            } while !Task.isCancelled
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            refresh += 1
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            refresh += 1
        }
    }

    private var totalCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Available Across Drives", systemImage: "externaldrive.fill")
                .font(.subheadline.weight(.semibold)).foregroundStyle(storageTint)
            Text(storage?.totalFree.map(ByteFormat.string) ?? "—")
                .font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                .contentTransition(.numericText())
            Text(totalCaption)
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(storageTint.opacity(0.09), in: .rect(cornerRadius: Metrics.radius))
        .overlay(RoundedRectangle(cornerRadius: Metrics.radius).strokeBorder(storageTint.opacity(0.2)))
        .accessibilityElement(children: .combine)
    }

    private var totalCaption: String {
        guard let storage else { return "Checking mounted drives…" }
        guard storage.totalFree != nil else { return "Drive readings unavailable" }
        return storage.hasMissingReadings ? "Some drive readings are unavailable" : "Mounted local drives"
    }

    private var startupCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SymbolTile(symbol: "internaldrive.fill", tint: storageTint, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Startup Disk").font(.headline)
                    if let disk = storage?.startup {
                        Text(disk.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let disk = storage?.startup {
                    Text("\(ByteFormat.string(disk.free)) free").font(.headline).monospacedDigit()
                }
            }
            .frame(height: 32)
            if let disk = storage?.startup {
                diskGraph(disk)
            } else {
                Text(storage == nil ? "Reading free space…" : "Free space unavailable")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(height: 26, alignment: .leading)
            }
            Divider().padding(.top, 3)
            HStack {
                Text("Free Space History").font(.caption.weight(.medium))
                Spacer()
                Text("Last 30 days").font(.caption).foregroundStyle(.secondary)
            }
            ZStack(alignment: .leading) {
                if let disk = storage?.startup { historyGraph(disk) }
            }
            .frame(height: 38)
        }
        .card(padding: 12)
    }

    private func diskGraph(_ disk: ConnectedStorage.StartupDisk) -> some View {
        let used = disk.capacity - disk.free
        return VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geometry in
                Capsule().fill(storageTint.opacity(0.17))
                    .overlay(alignment: .leading) {
                        storageTint.frame(width: geometry.size.width * CGFloat(used) / CGFloat(disk.capacity))
                    }
                    .clipShape(Capsule())
            }
            .frame(height: 7)
            .accessibilityHidden(true)
            HStack {
                Text("\(ByteFormat.string(used)) used")
                Spacer()
                Text("\(ByteFormat.string(disk.capacity)) total")
            }
            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .frame(height: 26)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func historyGraph(_ disk: ConnectedStorage.StartupDisk) -> some View {
        let since = Date.now.addingTimeInterval(-30 * 86_400)
        let points = model.storageMonitor.trend(including: model.scan.comparisonHistory.storageReadings,
                                                since: since, startup: disk)
        if points.count > 1, let first = points.first, let last = points.last {
            Chart(points) { point in
                LineMark(x: .value("Date", point.date), y: .value("Free bytes", point.free))
                    .foregroundStyle(storageTint)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: .automatic(includesZero: false))
            .accessibilityLabel("Startup disk free space history")
            .accessibilityValue("\(ByteFormat.string(first.free)) to \(ByteFormat.string(last.free)) over the recorded period")
        } else {
            Text("The trend appears after two saved readings.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func tile<Content: View>(_ title: String, symbol: String, tint: Color,
                                    @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold)).foregroundStyle(tint)
            content()
        }
        .frame(minHeight: 38, alignment: .topLeading)
        .card(padding: 10)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}
