import AppKit
import AndromedaAppModel
import AndromedaCore
import AndromedaOrganize
import Sparkle
import SwiftUI

/// The Settings scene keeps its categories beside the active page at every window width.
public struct SettingsView: View {
    let model: AppModel
    let updater: SPUUpdater?
    let showVersionHistory: (() -> Void)?
    let receivesPublicBetas: Binding<Bool>?
    let showsAutomationMenu: Binding<Bool>?
    let showsStorageMenu: Binding<Bool>?
    @State private var helperSheet = false
    @State private var confirmRemove = false
    @State private var working = false
    @State private var pane = Pane.general
    @FocusState private var focusedCategory: Pane?

    private enum Pane: CaseIterable {
        case general, organize, rules, automation, monitoring, updates

        var title: String {
            switch self {
            case .general: UICopy.settingsGeneral
            case .organize: Copy.Organize.settingsTitle
            case .rules: Copy.Organize.rulesTitle
            case .automation: "Automation"
            case .monitoring: "Monitoring"
            case .updates: "Updates"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .organize: "folder.badge.gearshape"
            case .rules: "list.bullet.rectangle"
            case .automation: "bolt"
            case .monitoring: "chart.xyaxis.line"
            case .updates: "arrow.trianglehead.clockwise"
            }
        }
    }

    public init(model: AppModel, updater: SPUUpdater? = nil, showsAutomationMenu: Binding<Bool>? = nil,
                showsStorageMenu: Binding<Bool>? = nil,
                showVersionHistory: (() -> Void)? = nil, receivesPublicBetas: Binding<Bool>? = nil) {
        self.model = model
        self.updater = updater
        self.showVersionHistory = showVersionHistory
        self.receivesPublicBetas = receivesPublicBetas
        self.showsAutomationMenu = showsAutomationMenu
        self.showsStorageMenu = showsStorageMenu
    }

    public var body: some View {
        HStack(spacing: 0) {
            categories
            ScrollView {
                page
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // A different category starts at the top of its own scroll view.
            .id(pane)
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Palette.canvas)
            .clipShape(.rect(topLeadingRadius: Metrics.windowContentCorner))
        }
            .frame(minWidth: 600, idealWidth: 730, maxWidth: .infinity,
                   minHeight: 600, idealHeight: 640, maxHeight: .infinity)
            .background(Palette.chrome)
            .containerBackground(Palette.chrome, for: .window)
            .navigationTitle("Andromeda Settings")
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .task {
                model.refreshOrganizeRoots()
                model.rules.reload()
                await model.helper.refresh()
            }
            .sheet(isPresented: $helperSheet) { HelperSheet(helper: model.helper) { helperSheet = false } }
            .alert(Copy.Helper.removeTitle, isPresented: $confirmRemove) {
                Button(UICopy.cancel, role: .cancel) {}.keyboardShortcut(.defaultAction)
                Button(Copy.Helper.removeConfirm, role: .destructive) {
                    // The helper may have become busy while the alert was open.
                    guard model.helper.canChangeHelper else { return }
                    run { await model.helper.remove() }
                }
            } message: {
                Text(Copy.Helper.removeBody)
            }
    }

    private var categories: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Pane.allCases, id: \.self) { category in
                Button {
                    pane = category
                    focusedCategory = category
                } label: {
                    Label {
                        Text(model.englishSpelling.wording(category.title))
                            .fontWeight(pane == category ? .semibold : .regular)
                    } icon: {
                        Image(systemName: category.symbol)
                            .foregroundStyle(pane == category ? Color.accentColor : Color.secondary)
                            .frame(width: 18)
                    }
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, minHeight: 33, alignment: .leading)
                    .contentShape(Rectangle())
                    .background {
                        if pane == category || focusedCategory == category {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color.primary.opacity(focusedCategory == category ? 0.19 : 0.12))
                        }
                    }
                }
                .buttonStyle(.plain)
                .focusable()
                .focused($focusedCategory, equals: category)
                .focusEffectDisabled()
                .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
                    let categories = Pane.allCases
                    guard let index = categories.firstIndex(of: category) else { return .ignored }
                    let nextIndex = index + (press.key == .upArrow ? -1 : 1)
                    if categories.indices.contains(nextIndex) {
                        pane = categories[nextIndex]
                        focusedCategory = pane
                    }
                    return .handled
                }
                .accessibilityAddTraits(pane == category ? .isSelected : [])
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 20)
        .frame(width: 166)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.chrome)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings categories")
    }

    @ViewBuilder private var page: some View {
        switch pane {
        case .general:
            VStack(alignment: .leading, spacing: 16) {
                if let showsStorageMenu {
                    Toggle("Show storage in the menu bar", isOn: showsStorageMenu).card()
                }
                form(.general)
                EnglishSpellingPicker(model: model).card()
            }
        case .organize: form(.organize)
        case .rules: form(.rules)
        case .automation: FolderAutomationSettings(model: model, showsAutomationMenu: showsAutomationMenu)
        case .monitoring:
            VStack(alignment: .leading, spacing: 16) {
                SectionHeading(title: "Storage Monitoring", symbol: Pane.monitoring.symbol, tint: .teal)
                StorageMonitoringSettingsView(model: model)
            }
            .card()
        case .updates: SoftwareUpdatesView(updater: updater, showVersionHistory: showVersionHistory,
                                           receivesPublicBetas: receivesPublicBetas)
        }
    }

    private func form(_ tab: SettingsForm.Tab) -> some View {
        SettingsForm(
            state: model.helper.state, statusText: model.helper.statusText,
            canChangeHelper: model.helper.canChangeHelper,
            canExport: model.canExport, working: working,
            onAction: { action in
                if action.needsExplainer { helperSheet = true } else { run { await model.helper.perform(action) } }
            },
            onRemove: { confirmRemove = true },
            onExport: { json in run { _ = await model.exportReport(json: json) } },
            onExportSupport: { run { _ = await model.exportSupportReport() } },
            organize: Bindable(model).organizeSettings, destinations: model.organizeDestinations,
            spelling: model.englishSpelling,
            rules: model.rules, volumes: model.drives.volumes, home: model.scanHome, tab: tab)
    }

    private func run(_ work: @escaping () async -> Void) {
        Task {
            working = true
            await work()
            working = false
        }
    }
}

struct SettingsForm: View {
    let state: HelperState
    /// The model's status sentence; defaults to the state's own.
    var statusText: String?
    /// False while a scan measures through the helper or a removal uses it.
    var canChangeHelper = true
    let canExport: Bool
    let working: Bool
    let onAction: (HelperAction) -> Void
    let onRemove: () -> Void
    let onExport: (Bool) -> Void
    var onExportSupport: (() -> Void)?
    var organize: Binding<OrganizeSettings> = .constant(OrganizeSettings())
    var destinations: [OrganizeDestination] = []
    var spelling: EnglishSpelling = .us
    /// Settings › Rules; nil leaves the section out.
    var rules: RulesModel? = nil
    /// The mounted drives, for a drive rule's "On <name>".
    var volumes: [ExternalVolume] = []
    var home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    /// The Settings window shows one tab at a time; nil (render tests) shows every section.
    var tab: Tab? = nil

    enum Tab { case general, organize, rules }

    private func shows(_ t: Tab) -> Bool { tab == nil || tab == t }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if shows(.general) { general }
            if shows(.organize) {
                OrganizeSettingsSection(settings: organize, destinations: destinations, home: home, spelling: spelling).card()
            }
            if shows(.rules), let rules {
                RulesSection(rules: rules, volumes: volumes, home: home, spelling: spelling).card()
            }
        }
        // The settings scroll view can grow the content when a status wraps.
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var general: some View {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeading(title: Copy.Helper.title, symbol: "lock.shield.fill", tint: .gray)
                // Keeps every line when a longer status arrives after the window was sized (F9).
                Text(statusText ?? state.statusText).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if let action = state.action {
                        Button(action.settingsTitle) { onAction(action) }.disabled(working || !canChangeHelper)
                    }
                    if state.canRemove {
                        Button(Copy.Helper.removeButton, action: onRemove).disabled(working || !canChangeHelper)
                    }
                }
            }
            .card()
            VStack(alignment: .leading, spacing: 8) {
                SectionHeading(title: UICopy.exportHeading, subtitle: UICopy.exportSubtitle, symbol: "doc.text.fill", tint: .blue)
                HStack {
                    if let onExportSupport {
                        Button(UICopy.exportSupport, action: onExportSupport)
                    }
                    Menu(UICopy.exportDetailed) {
                        Button(UICopy.exportText) { onExport(false) }
                        Button(UICopy.exportJSON) { onExport(true) }
                    }
                    .fixedSize()
                }
                .disabled(!canExport || working)
            }
            .card()
    }
}

/// Thresholds as steppers (sizes in MB, ages in days) and one read-only destination row per cloud folder.
struct OrganizeSettingsSection: View {
    @Binding var settings: OrganizeSettings
    let destinations: [OrganizeDestination]
    var home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    var spelling: EnglishSpelling = .us

    private static let mb: Int64 = 1_000_000

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading(title: spelling.wording(Copy.Organize.settingsTitle), subtitle: Copy.Organize.settingsSubtitle,
                           symbol: "folder.badge.gearshape", tint: .indigo)
            Group {
                Text(Copy.Organize.cloudTitle).font(.headline)
                Text("Suggest removing local downloads of items that are already in the cloud.")
                    .font(.callout).foregroundStyle(.secondary)
                sizeStepper(Copy.Organize.offloadSize, $settings.offloadMinBytes, minimum: OrganizeSettings.minOffloadBytes, step: 50)
                dayStepper(Copy.Organize.offloadAge, $settings.offloadMinAge)
            }
            Divider().padding(.vertical, 5)
            Group {
                Text(Copy.Organize.moveToCloudTitle).font(.headline)
                Text("Suggest local items to move. Protect folders whose files should stay together on this Mac.")
                    .font(.callout).foregroundStyle(.secondary)
                sizeStepper(Copy.Organize.moveSize, $settings.moveMinBytes, minimum: OrganizeSettings.minMoveBytes, step: 100)
                dayStepper(Copy.Organize.moveAge, $settings.moveMinAge)
            }
            protectedProjects
            Divider().padding(.vertical, 5)
            Text(Copy.Organize.destinationsHeading).font(.headline).padding(.top, 4)
            if destinations.isEmpty {
                Text(Copy.Organize.noCloudFolders).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(destinations) { row in
                HStack(spacing: 10) {
                    ProviderIconView(provider: row.provider, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.title).font(.callout)
                        Text(Copy.Scan.displayPath(URL(fileURLWithPath: row.path), home: home))
                            .font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
        }
    }

    private var protectedProjects: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Protected project folders").font(.subheadline.weight(.semibold))
                Spacer()
                Button("Add Folder…", action: chooseProtectedFolder)
            }
            ForEach(settings.moveProtectedFolders, id: \.self) { path in
                HStack {
                    Text(Copy.Scan.displayPath(URL(fileURLWithPath: path), home: home))
                        .lineLimit(1).truncationMode(.middle).help(path)
                    Spacer()
                    Button("Remove", systemImage: "minus.circle") {
                        settings.moveProtectedFolders.removeAll { $0 == path }
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("Remove protection for \(URL(fileURLWithPath: path).lastPathComponent)")
                }
            }
        }
    }

    private func chooseProtectedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = home
        panel.prompt = "Protect"
        guard panel.runModal() == .OK, let folder = panel.url?.standardizedFileURL.path,
              !settings.moveProtectedFolders.contains(folder) else { return }
        settings.moveProtectedFolders.append(folder)
    }

    private func sizeStepper(_ title: String, _ bytes: Binding<Int64>, minimum: Int64, step: Int) -> some View {
        let megabytes = Binding<Int>(
            get: { Int(bytes.wrappedValue / Self.mb) }, set: { bytes.wrappedValue = Int64($0) * Self.mb })
        return Stepper(value: megabytes, in: Int(minimum / Self.mb)...100_000, step: step) {
            HStack { Text(title); Spacer(); Text(Copy.Organize.megabytes(megabytes.wrappedValue)).monospacedDigit() }
        }
    }

    private func dayStepper(_ title: String, _ age: Binding<TimeInterval>) -> some View {
        let days = Binding<Int>(
            get: { Int((age.wrappedValue / OrganizeSettings.day).rounded()) },
            set: { age.wrappedValue = TimeInterval($0) * OrganizeSettings.day })
        return Stepper(value: days, in: Int(OrganizeSettings.minAge / OrganizeSettings.day)...3650, step: 7) {
            HStack { Text(title); Spacer(); Text(Copy.Organize.days(days.wrappedValue)).monospacedDigit() }
        }
    }
}

/// Settings › Rules (plan 6): each saved rule's pattern, destination and scope, with **Edit rule** and
/// **Delete rule**; the note when the rules file can't be read, and why a rule wasn't used last time.
/// Deleting or editing a rule changes only the rules file, never a file of the user's, so neither asks first;
/// **Start over with no rules** replaces the unreadable file, behind a confirm whose default is Cancel.
struct RulesSection: View {
    let rules: RulesModel
    var volumes: [ExternalVolume] = []
    let home: URL
    var spelling: EnglishSpelling = .us
    @State private var confirmReplace = false
    @State private var editing: UUID?
    @State private var pattern = ""
    @State private var destination = ""
    @State private var problem: String?
    /// Why the last delete or start-over couldn't be saved.
    @State private var listProblem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading(title: spelling.wording(Copy.Organize.rulesTitle),
                           subtitle: spelling.wording(Copy.Organize.rulesSubtitle),
                           symbol: "list.bullet.rectangle.fill", tint: .orange)
            if let listProblem {
                Text(listProblem).font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if rules.unreadable {
                Text(Copy.Organize.rulesUnreadable).font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button(Copy.Organize.replaceRules) { confirmReplace = true }
                    .accessibilityLabel(Copy.Organize.replaceRules)
            } else if rules.rules.isEmpty {
                Text(Copy.Organize.rulesEmpty).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(rules.rules) { rule in
                if editing == rule.id { editor(rule) } else { row(rule) }
            }
        }
        .alert(Copy.Organize.replaceRulesConfirmTitle, isPresented: $confirmReplace) {
            Button(UICopy.cancel, role: .cancel) {}.keyboardShortcut(.defaultAction)
            Button(Copy.Organize.replaceRules, role: .destructive) { listProblem = rules.replaceUnreadable() }
        } message: {
            Text(Copy.Organize.replaceRulesConfirmBody)
        }
    }

    private func row(_ rule: OrganizeRule) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(rule.pattern).font(.callout.monospaced())
                let onDrive = rule.volumeUUID != nil
                Text(Copy.Organize.ruleDestinationText(rule.destination, home: home, onDrive: onDrive)).font(.caption)
                    .lineLimit(2).truncationMode(.middle)
                Text(Copy.Organize.ruleScopeText(rule.scope, home: home, onDrive: onDrive)).font(.caption)
                    .foregroundStyle(.secondary)
                if let drive = RulesModel.driveText(rule, volumes: volumes) {
                    Text(drive).font(.caption).foregroundStyle(.secondary)
                }
                if let why = rules.blocked[rule.id] {
                    Text(Copy.Organize.ruleBlocked(why)).font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Button(Copy.Organize.editRule) {
                pattern = rule.pattern
                destination = RulesModel.destinationPath(rule)
                problem = nil
                editing = rule.id
            }
            .accessibilityLabel(Copy.Organize.editRuleLabel(rule.pattern))
            Button(Copy.Organize.deleteRule) { listProblem = rules.delete(id: rule.id) }
                .accessibilityLabel(Copy.Organize.deleteRuleLabel(rule.pattern))
        }
    }

    private func editor(_ rule: OrganizeRule) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(Copy.Organize.rulePattern, text: $pattern)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(Copy.Organize.rulePattern)
            HStack(spacing: 4) {
                if case .inHome = rule.destination, rule.volumeUUID == nil {
                    Text(Copy.Organize.ruleHomePrefix).font(.callout.monospaced())
                }
                TextField(Copy.Organize.ruleDestination, text: $destination)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(Copy.Organize.ruleDestination)
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button(UICopy.cancel) { editing = nil }.keyboardShortcut(.cancelAction)
                    .accessibilityLabel(UICopy.cancel)
                Button(Copy.Organize.saveRule) {
                    problem = rules.edit(id: rule.id, pattern: pattern, destinationPath: destination)
                    if problem == nil { editing = nil }
                }
                .accessibilityLabel(Copy.Organize.saveRule)
            }
        }
    }
}
