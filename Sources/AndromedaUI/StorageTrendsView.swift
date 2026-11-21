import Charts
import AndromedaAppModel
import AndromedaCore
import SwiftUI
import UniformTypeIdentifiers

struct StorageTrendsView: View {
    let model: AppModel
    let ui: UIState
    @State private var range: Range = .month
    @State private var selection: Date?
    @State private var investigatingAlert: UUID?
    @State private var investigationProblem: String?
    @State private var exportDocument: StartupHistoryDocument?
    @State private var isExporting = false
    @State private var exportFailed = false
    private var monitor: StorageMonitor { model.storageMonitor }
    private static let gb = 1_000_000_000.0

    private enum Range: Int, CaseIterable {
        case week = 7, month = 30, quarter = 90, year = 365, all = 0

        var title: String {
            switch self {
            case .week, .month, .quarter: "\(rawValue) days"
            case .year: "1 year"
            case .all: "All time"
            }
        }

        var since: Date { self == .all ? .distantPast : Date().addingTimeInterval(-Double(rawValue) * 86_400) }
    }

    var body: some View {
        PageColumn {
            PageHeader(title: "Storage Trends", subtitle: "See how much free space your Mac has over time.",
                       symbol: "chart.xyaxis.line") {
                Button("Check Now", systemImage: "arrow.clockwise") { Task { await monitor.checkNow() } }
                    .disabled(monitor.isChecking)
            }
            if let problem = monitor.problem {
                Banner(text: problem, symbol: "exclamationmark.triangle", tint: .orange)
            }
            if let investigationProblem {
                Banner(text: investigationProblem, symbol: "exclamationmark.triangle", tint: .orange)
            }
            if monitor.isChecking {
                HStack { ProgressView().controlSize(.small); Text("Checking storage…") }.card()
            }
            trendCard
            WatchedFoldersSection(model: model, since: range.since) { ui.destination = .spacePlan }
            DisclosureGroup("Monitoring Settings") {
                StorageMonitoringSettingsView(model: model).padding(.top, 12)
            }
            .card()
            SectionHeading(title: "Recent Alerts")
            if monitor.alerts.isEmpty {
                Text("Storage alerts will appear here.").foregroundStyle(.secondary).card()
            } else {
                LazyInsetList(items: monitor.alerts) { alertRow($0) }
            }
        }
        .fileExporter(isPresented: $isExporting, document: exportDocument, contentType: .commaSeparatedText,
                      defaultFilename: "Andromeda Startup Storage History") { result in
            if case .failure = result { exportFailed = true }
        }
        .alert("Couldn’t Export Startup History", isPresented: $exportFailed) {
            Button("OK", role: .cancel) {}
        }
    }

    private var trendCard: some View {
        let scans = model.scan.comparisonHistory.storageReadings
        let points = monitor.trend(including: scans, since: range.since)
        let selected = selection.flatMap { date in
            points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
        }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeading(title: "Startup disk free space")
                Spacer()
                Picker("Time range", selection: $range) {
                    ForEach(Range.allCases, id: \.self) { value in Text(value.title).tag(value) }
                }
                .pickerStyle(.menu).labelsHidden()
                .onChange(of: range) { selection = nil }
            }
            if let latest = points.last {
                let reading = selected ?? latest
                Text("\(ByteFormat.string(reading.free)) free").font(.title2.weight(.semibold)).monospacedDigit()
                Text(reading.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.callout).foregroundStyle(.secondary)
                chart(points, selected: selected)
                if points.count == 1 {
                    Text("The trend line appears after your next reading.").font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Text("Check now or run a scan to start recording free space.")
                    .foregroundStyle(.secondary)
            }
            Text(monitor.settings.automaticChecks
                 ? "Automatic checks are on · \(monitor.settings.interval.title)"
                 : "Automatic checks are off. Turn them on in Monitoring Settings.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Export Startup History…", systemImage: "square.and.arrow.up") {
                guard let csv = monitor.startupHistoryCSV(including: scans) else { return }
                exportDocument = StartupHistoryDocument(data: csv)
                isExporting = true
            }
            .disabled(scans.isEmpty && monitor.readings.isEmpty)
            .help("Save retained readings for this startup disk and capacity as CSV. The file contains dates and byte counts.")
            if range == .year || range == .all {
                Text("Andromeda keeps the last check per day after 90 days and per week after a year.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .card()
    }

    private func chart(_ points: [StorageReading], selected: StorageReading?) -> some View {
        let values = points.map { Double($0.free) / Self.gb }
        let low = values.min() ?? 0
        let high = values.max() ?? 0
        let margin = max(0.25, (high - low) * 0.15)
        return Chart {
            ForEach(points) { point in
                LineMark(x: .value("Date", point.date), y: .value("Free GB", Double(point.free) / Self.gb))
                if points.count <= 30 {
                    PointMark(x: .value("Date", point.date), y: .value("Free GB", Double(point.free) / Self.gb))
                        .symbolSize(18)
                }
            }
            if let selected {
                RuleMark(x: .value("Selected reading", selected.date))
                    .foregroundStyle(.secondary.opacity(0.4))
            }
        }
        .chartYScale(domain: max(0, low - margin)...(high + margin))
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let gb = value.as(Double.self) {
                        Text("\(gb.formatted(.number.precision(.fractionLength(0...1)))) GB")
                    }
                }
            }
        }
        .chartXSelection(value: $selection)
        .frame(height: 235)
        .accessibilityLabel("Startup disk free space over time")
    }

    private func alertRow(_ alert: StorageAlert) -> some View {
        let title: String
        let symbol: String
        switch alert.kind {
        case .lowSpace: (title, symbol) = ("Low disk space", "exclamationmark.triangle")
        case .folderReturned: (title, symbol) = ("A cleaned folder grew back", "folder.badge.plus")
        case .rapidDrop: (title, symbol) = ("Free space dropped quickly", "arrow.down.right")
        case .watchedFolderLimit: (title, symbol) = ("A watched folder reached its size limit", "folder.badge.exclamationmark")
        }
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.orange).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                if let path = alert.path {
                    let url = URL(fileURLWithPath: path, isDirectory: true)
                    Text(Copy.Scan.displayPath(url, home: model.scanHome)).textSelection(.enabled)
                    Text(alert.kind == .watchedFolderLimit ? "\(ByteFormat.string(alert.bytes)) on disk."
                         : "At least \(ByteFormat.string(alert.bytes)) on disk.").foregroundStyle(.secondary)
                } else if alert.kind == .rapidDrop {
                    Text("\(ByteFormat.string(alert.bytes)) less free space than a reading in the last 24 hours.")
                        .foregroundStyle(.secondary)
                    if let growth = alert.folderGrowth {
                        let folder = URL(fileURLWithPath: growth.path, isDirectory: true)
                        let name = growth.catalogTitle ?? Copy.Scan.displayPath(folder, home: model.scanHome)
                        Text("Largest measured increase was \(ByteFormat.string(growth.bytes)) in \(name).")
                            .textSelection(.enabled)
                        Text("Scans from \(growth.earlierDate.formatted(date: .abbreviated, time: .shortened)) to \(growth.laterDate.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                        if growth.laterDate > alert.date {
                            Text("Measured in a follow-up scan after this alert.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("\(ByteFormat.string(alert.bytes)) free on your startup disk.").foregroundStyle(.secondary)
                }
                Text(alert.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let path = alert.path {
                Button("Show in Finder") { model.reveal(URL(fileURLWithPath: path)) }
            } else if alert.kind == .rapidDrop {
                if monitor.canInvestigate(alert) {
                    Button(investigatingAlert == alert.id ? "Investigating…" : "Scan to Investigate") {
                        Task { await investigate(alert) }
                    }
                    .disabled(!model.canScan || investigatingAlert != nil)
                } else {
                    Button("Open What changed?") { openComparison(alert.folderGrowth) }
                }
            } else {
                Button("Open Space Plan") { ui.destination = .spacePlan }
            }
        }
        .groupRow()
    }

    private func investigate(_ alert: StorageAlert) async {
        guard model.canScan, investigatingAlert == nil, monitor.canInvestigate(alert) else { return }
        investigatingAlert = alert.id
        investigationProblem = nil
        defer { investigatingAlert = nil }
        await model.scan()
        guard ui.destination == .storageTrends else { return }
        if let growth = monitor.alerts.first(where: { $0.id == alert.id })?.folderGrowth {
            openComparison(growth)
        } else {
            investigationProblem = "The scan couldn’t find a measurable increase at a location covered by both scans."
        }
    }

    private func openComparison(_ growth: StorageAlert.FolderGrowth?) {
        ui.destination = .scanComparison
        let scans = model.scan.comparisonHistory.snapshots
        if let growth, scans.contains(where: { $0.id == growth.earlierScan }),
           scans.contains(where: { $0.id == growth.laterScan }) {
            ui.comparisonEarlierID = growth.earlierScan
            ui.comparisonLaterID = growth.laterScan
        }
    }
}

private struct StartupHistoryDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.commaSeparatedText]
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        data = contents
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct WatchedFoldersSection: View {
    let model: AppModel
    let since: Date
    let openPlan: () -> Void
    @State private var draft: Draft?
    @State private var problem = false
    private var monitor: StorageMonitor { model.storageMonitor }

    private struct Draft: Identifiable {
        let id = UUID()
        let url: URL
        let watchID: UUID?
        let limitMB: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeading(title: "Watched Folders", subtitle: "Track size and get an alert when a folder reaches its limit.")
                Spacer()
                Button("Watch Folder…", systemImage: "folder.badge.plus") {
                    Task {
                        if let url = await model.chooseStorageFolder() {
                            draft = Draft(url: url, watchID: nil, limitMB: 5_000)
                        }
                    }
                }
                .disabled(monitor.watchedFolders.count >= 8)
            }
            ForEach(monitor.watchedFolders) { folder in
                DisclosureGroup {
                    folderDetails(folder)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(Copy.Scan.displayPath(folder.reference.url, home: model.scanHome)).font(.headline)
                        Text(folderStatus(folder)).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .card()
        .sheet(item: $draft) { draft in
            WatchFolderSheet(url: draft.url, initialLimit: draft.limitMB, editing: draft.watchID != nil) { limit in
                Task {
                    let saved: Bool
                    if let id = draft.watchID { saved = await monitor.setWatchedFolderLimit(id, limitMB: limit) }
                    else { saved = await monitor.watchFolder(draft.url, limitMB: limit) }
                    problem = !saved
                    if saved { await monitor.checkNow() }
                }
            }
        }
        .alert("Couldn’t Save Watched Folder", isPresented: $problem) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Choose a readable local folder inside your home folder. You can watch up to eight folders.")
        }
    }

    private func folderStatus(_ folder: WatchedStorageFolder) -> String {
        let limit = ByteFormat.string(Int64(folder.limitMB) * 1_000_000)
        let latest = folder.readings.last.map { "\(ByteFormat.string($0.bytes)) on disk" } ?? "Awaiting first reading"
        return "\(folder.unavailable ? "Latest check unavailable · " : "")\(latest) · Limit \(limit)"
    }

    private func folderDetails(_ folder: WatchedStorageFolder) -> some View {
        let points = folder.readings.filter { $0.date >= since }
        return VStack(alignment: .leading, spacing: 10) {
            if let latest = points.last {
                Text(latest.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if points.count > 1 {
                Chart(points) { point in
                    LineMark(x: .value("Date", point.date), y: .value("Size (MB)", Double(point.bytes) / 1_000_000))
                    if points.count <= 30 {
                        PointMark(x: .value("Date", point.date), y: .value("Size (MB)", Double(point.bytes) / 1_000_000))
                            .symbolSize(18)
                    }
                }
                .chartYAxisLabel("MB on disk")
                .frame(height: 145)
                .accessibilityLabel("Watched folder size over time")
            } else {
                Text("Two readings in the selected time range are needed to show a trend.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("Add to Space Plan") {
                    model.spacePlanner.addFolderForReview(folder)
                    openPlan()
                }
                Button("Edit Limit…") {
                    draft = Draft(url: folder.reference.url, watchID: folder.id, limitMB: folder.limitMB)
                }
                Spacer()
                Button("Stop Watching") { Task { await monitor.stopWatching(folder.id) } }
            }
        }
        .padding(.top, 8)
    }
}

private struct WatchFolderSheet: View {
    let url: URL
    let editing: Bool
    let save: (Int) -> Void
    @State private var limit: String
    @Environment(\.dismiss) private var dismiss

    init(url: URL, initialLimit: Int, editing: Bool, save: @escaping (Int) -> Void) {
        self.url = url
        self.editing = editing
        self.save = save
        _limit = State(initialValue: String(initialLimit))
    }

    var body: some View {
        let value = Int(limit.trimmingCharacters(in: .whitespacesAndNewlines))
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(title: editing ? "Edit Folder Limit" : "Watch Folder", symbol: "folder.badge.plus", tint: .indigo)
            Text(url.path).textSelection(.enabled)
            TextField("Size limit (MB)", text: $limit).accessibilityLabel("Size limit (MB)")
            Text("Use 1 to 1,000,000 MB. Checks follow the monitoring schedule. Some folders require Full Disk Access.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button(editing ? "Save Limit" : "Watch Folder") {
                    if let value { save(value) }
                    dismiss()
                }
                .disabled(value.map { !(1...1_000_000).contains($0) } ?? true)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 420)
    }
}

struct StorageMonitoringSettingsView: View {
    let model: AppModel

    var body: some View {
        @Bindable var monitor = model.storageMonitor
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Check storage automatically", isOn: $monitor.settings.automaticChecks)
            Picker("Check frequency", selection: $monitor.settings.interval) {
                ForEach(StorageMonitoringSettings.Interval.allCases) { interval in
                    Text(interval.title).tag(interval)
                }
            }
            .disabled(!monitor.settings.automaticChecks)
            Text("Andromeda checks watched folders when they change while the app is running. New automatic checks wait in Low Power Mode or when macOS reports high thermal pressure.")
                .font(.callout).foregroundStyle(.secondary)
            Divider()
            Toggle("Alert when free space gets low", isOn: $monitor.settings.lowSpaceAlerts)
            Stepper(value: $monitor.settings.lowSpaceGB, in: 1...500) {
                Text("Free-space threshold: \(monitor.settings.lowSpaceGB) GB")
            }
            .disabled(!monitor.settings.lowSpaceAlerts)
            Toggle("Alert when free space drops quickly", isOn: $monitor.settings.rapidDropAlerts)
            if monitor.settings.rapidDropAlerts {
                Text("Checks for a drop of 10 GB or 5% of disk capacity within 24 hours, whichever is smaller.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Toggle("Alert when a cleaned folder grows back", isOn: $monitor.settings.regrowthAlerts)
            Stepper(value: $monitor.settings.regrowthMB, in: 100...10_000, step: 100) {
                Text("Folder size threshold: \(monitor.settings.regrowthMB) MB")
            }
            .disabled(!monitor.settings.regrowthAlerts)
            Text("Folder alerts watch recent folders moved to Trash through Andromeda cleanup.")
                .font(.callout).foregroundStyle(.secondary)
            Divider()
            switch monitor.notificationStatus {
            case .allowed:
                Toggle("Show macOS notifications", isOn: $monitor.settings.systemNotifications)
            case .needsPermission:
                Button("Enable macOS Notifications") { Task { await monitor.enableNotifications() } }
            case .denied:
                SettingsNotificationsLink()
            case .unavailable:
                EmptyView()
            }
            Text("Alerts appear in Storage Trends. macOS notifications are optional.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .task { await monitor.refreshNotificationStatus() }
    }
}

struct SettingsNotificationsLink: View {
    var body: some View {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            Link("Open macOS Notification Settings", destination: url)
        }
    }
}
