import AppKit
import AndromedaAppModel
import AndromedaCore
import AndromedaOrganize
import SwiftUI

struct FolderAutomationSettings: View {
    let model: AppModel
    var showsAutomationMenu: Binding<Bool>? = nil
    @State private var draft: Draft?
    @State private var reapplyRule: FolderAutomationRule?
    @State private var problem: String?
    @State private var loginItem = LoginItemModel()
    @State private var ruleSearch = ""

    private struct Draft: Identifiable {
        let id = UUID()
        var rule: FolderAutomationRule?
    }

    private var automation: FolderAutomationModel { model.folderAutomation }

    var body: some View {
        let displayedRules = Self.filteredRules(automation.rules, query: ruleSearch)
        let activeReapply = automation.rules.first { automation.isReapplying($0.id) }
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeading(title: "Folder Automation",
                               subtitle: "Watch a folder and act on matching files automatically. Review and undo changes in History.",
                               symbol: "bolt.fill", tint: .indigo)
                Button("Add Rule…") { draft = Draft() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!automation.available)
                if automation.rules.isEmpty && automation.available {
                    Text("Choose a watched folder, a condition, and an action. For example, copy PDFs from Downloads into a receipts folder. Preview a file before enabling the rule.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let message = problem ?? automation.settingsProblem {
                    Text(message).foregroundStyle(.secondary)
                } else if !automation.available {
                    Text("Automation needs a writable History.").foregroundStyle(.secondary)
                }
            }
            if !automation.rules.isEmpty || !ruleSearch.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Rules").font(.headline).accessibilityAddTraits(.isHeader)
                    Text("For each folder, the first enabled rule that matches a file takes priority.")
                        .font(.callout).foregroundStyle(.secondary)
                    ruleSearchField
                    if displayedRules.isEmpty && !ruleSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Label("No rules match your search.", systemImage: "magnifyingglass")
                            .font(.callout).foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    }
                    LazyVStack(spacing: 8) {
                        ForEach(displayedRules) { rule in
                            ruleCard(rule, activeReapply: activeReapply)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Automation Options").font(.headline).accessibilityAddTraits(.isHeader)
                runtimeSettings
            }
            .card()
        }
        .sheet(item: $draft) { draft in
            AutomationRuleSheet(model: model, rule: draft.rule) { self.draft = nil }
        }
        .sheet(item: $reapplyRule) { rule in
            FolderAutomationCopyReview(automation: automation, rule: rule)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
            model.folderAutomationService.refresh()
        }
        .onAppear { model.folderAutomationService.refresh() }
    }

    private func ruleCard(_ rule: FolderAutomationRule, activeReapply: FolderAutomationRule?) -> some View {
        let label = rule.pattern.isEmpty
            ? rule.fileExtension.map { ".\($0)" } ?? rule.finderTag ?? rule.fileKind?.folderName ?? "file"
            : rule.pattern
        let source = rule.directories.source
        let paused = automation.isPaused(source)
        let runningOnce = automation.isRunningOnce(source)
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(rule.directories.source.url.lastPathComponent)
                    .font(.headline)
                Text(Self.matchSummary(rule))
                    .lineLimit(2)
                Text(Self.actionSummary(rule))
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(scheduleSummary(for: rule, folderPaused: paused))
                    .font(.caption).foregroundStyle(.secondary)
                if activeReapply?.id == rule.id {
                    Text("Reapplying copy rule…").font(.caption).foregroundStyle(.secondary)
                } else if runningOnce && activeReapply?.directories.source != source && rule.enabled {
                    Text("Running rules once…").font(.caption).foregroundStyle(.secondary)
                } else if rule.enabled && !automation.runsInBackground(source), let status = automation.status[rule.id],
                          status != "Watching for matching files." {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                ruleDetails(rule)
            }
            Spacer(minLength: 8)
            Toggle("Enable \(label) rule for \(rule.directories.source.url.lastPathComponent)", isOn: Binding(
                get: { rule.enabled }, set: { problem = automation.setEnabled($0, id: rule.id) }))
                .labelsHidden().toggleStyle(.switch)
            Menu {
                Button("Edit Rule…") { draft = Draft(rule: rule) }
                Button("Duplicate Rule…") {
                    switch automation.duplicate(id: rule.id) {
                    case .success(let copy):
                        problem = nil
                        draft = Draft(rule: copy)
                    case .failure(let error): problem = error.message
                    }
                }
                .disabled(!automation.available)
                Button("Move Earlier") { problem = automation.move(id: rule.id, earlier: true) }
                    .disabled(!automation.canMove(id: rule.id, earlier: true))
                Button("Move Later") { problem = automation.move(id: rule.id, earlier: false) }
                    .disabled(!automation.canMove(id: rule.id, earlier: false))
                Button(paused ? "Resume Folder" : "Pause Folder") {
                    problem = automation.setPaused(!paused, source: source)
                }
                .disabled(!automation.available)
                if runningOnce {
                    Button(activeReapply?.directories.source == source ? "Cancel Copy Reapply" : "Cancel One-Time Run") {
                        automation.cancelRunOnce(source)
                    }
                } else {
                    Button("Run Folder Rules Once") { automation.runOnce(source) }
                        .disabled(!automation.canRunOnce(source))
                }
                if rule.copiesMatches {
                    Button(reapplyTitle(for: rule, paused: paused)) {
                        reapplyRule = rule
                    }
                    .disabled(!automation.canReviewReplay(ruleID: rule.id))
                }
                Divider()
                Button("Remove Rule", role: .destructive) { problem = automation.remove(id: rule.id) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Options for \(label) in \(rule.directories.source.path)")
        }
        .card()
    }

    private func ruleDetails(_ rule: FolderAutomationRule) -> some View {
        DisclosureGroup("Rule details") {
            VStack(alignment: .leading, spacing: 3) {
                Text("Watched folder: \(rule.directories.source.path)")
                if rule.includesSubfolders {
                    let scope = rule.maximumSubfolderDepth.map {
                        $0 == 1 ? "Includes 1 subfolder level" : "Includes up to \($0) subfolder levels"
                    } ?? "Includes subfolders"
                    Text(scope)
                }
                if rule.preservesSubfolderStructure {
                    Text(rule.folderStructure == .immediateParent ? "Keeps the immediate parent folder" : "Keeps subfolder structure")
                }
                if let pattern = rule.includedSubfolderPattern {
                    Text("Includes folders matching \(pattern)")
                }
                if let pattern = rule.excludedSubfolderPattern {
                    Text("Skips folders matching \(pattern)")
                }
                if rule.directories.destination != rule.directories.source {
                    Text("Destination: \(rule.directories.destination.path)")
                }
                if let template = rule.subfolderTemplate {
                    Text("Subfolder pattern: \(template.pattern)")
                }
                if !rule.pattern.isEmpty {
                    Text("Filename matches “\(rule.pattern)”")
                }
                ForEach(rule.backupFolders, id: \.self) { backup in
                    Text("Back up to \(backup.path)")
                }
                if rule.numbersBackupConflicts {
                    Text("Numbers new backups when a name is taken")
                }
                if let kind = rule.fileKind {
                    Text("Kind is \(kind.folderName)")
                }
                if !rule.finderTags.isEmpty {
                    Text("Finder tags \(Self.tagSummary(rule.finderTags))")
                }
                if !rule.excludedFinderTags.isEmpty {
                    Text("Skips files tagged \(Self.tagSummary(rule.excludedFinderTags))")
                }
                if !rule.copyFinderTags.isEmpty {
                    Text(rule.backupFolder == nil
                         ? "Adds tags to copies · \(Self.tagSummary(rule.copyFinderTags))"
                         : "Adds tags to backups · \(Self.tagSummary(rule.copyFinderTags))")
                }
                if !rule.copyTagTemplates.isEmpty {
                    Text(rule.backupFolder == nil
                         ? "Generates tags for copies · \(Self.tagSummary(rule.copyTagTemplates.map(\.pattern)))"
                         : "Generates tags for backups · \(Self.tagSummary(rule.copyTagTemplates.map(\.pattern)))")
                }
                if !rule.removedCopyTags.isEmpty {
                    Text(rule.backupFolder == nil
                         ? "Removes tags from copies · \(Self.tagSummary(rule.removedCopyTags))"
                         : "Removes tags from backups · \(Self.tagSummary(rule.removedCopyTags))")
                }
                if rule.skipsIdenticalCopies {
                    Text("Skips identical copies")
                }
                if rule.copiesOnArrival {
                    Text("Copies completed arrivals immediately")
                }
                if let prefix = rule.renamePrefix {
                    Text("Adds “\(prefix)” to filenames")
                }
                if let template = rule.renameTemplate {
                    Text("Uses “\(template.pattern)” for filenames")
                }
                if rule.collisionPolicy == .numberIncoming {
                    Text("Adds a number when a name is taken")
                }
                if let minimumBytes = rule.minimumBytes {
                    Text("At least \(ByteFormat.string(minimumBytes))")
                }
                if let maximumBytes = rule.maximumBytes {
                    Text("At most \(ByteFormat.string(maximumBytes))")
                }
                if let minimumAgeDays = rule.minimumAgeDays {
                    Text("\(rule.ageBasis.title) at least \(minimumAgeDays) days ago")
                }
                if let maximumAgeDays = rule.maximumAgeDays {
                    Text("\(rule.ageBasis.title) within \(maximumAgeDays) days")
                }
                if rule.matchMode == .any {
                    Text("Matches any condition")
                } else if rule.matchMode == .none {
                    Text("Matches when no condition is met")
                }
                if let fileExtension = rule.fileExtension {
                    Text("File extension is .\(fileExtension)")
                }
                if let phrase = rule.contentsContains {
                    Text("Contents contain “\(phrase)”").lineLimit(1)
                }
                if !rule.conditionGroups.isEmpty {
                    Text("Includes nested conditions")
                }
                if rule.notifiesOnCompletion {
                    Text("Notifies after organizing files")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static func matchSummary(_ rule: FolderAutomationRule) -> String {
        var conditions = [
            rule.pattern.isEmpty ? nil : "filename matches “\(rule.pattern)”",
            rule.fileExtension.map { "extension is .\($0)" },
            rule.fileKind.map { "kind is \($0.folderName)" },
            rule.contentsContains.map { "contents contain “\($0)”" },
            rule.minimumBytes != nil || rule.maximumBytes != nil ? "file size is in range" : nil,
            rule.minimumAgeDays != nil || rule.maximumAgeDays != nil ? "file age is in range" : nil
        ].compactMap { $0 }
        conditions.append(contentsOf: rule.finderTags.map { "tag is “\($0)”" })

        let count = conditions.count + rule.conditionGroups.count
        if count == 0 { return "All files except excluded tags" }
        if count == 1, rule.matchMode != .none, let condition = conditions.first {
            return "Matches if \(condition)"
        }
        if count == 1 {
            return rule.matchMode == .none ? "Matches when the condition is false" : "Matches a condition group"
        }
        switch rule.matchMode {
        case .all: return "Matches all \(count) conditions"
        case .any: return "Matches any of \(count) conditions"
        case .none: return "Matches when none of \(count) conditions are met"
        }
    }

    private static func actionSummary(_ rule: FolderAutomationRule) -> String {
        let destination = rule.directories.destination.url.lastPathComponent
        switch AutomationRuleAction(rule) {
        case .copy: return "Copies to \(destination)"
        case .move: return "Moves to \(destination)"
        case .copyThenMove: return "Backs up, then moves to \(destination)"
        case .rename: return rule.backupFolder == nil ? "Renames in place" : "Backs up, then renames in place"
        case .sort: return rule.backupFolder == nil ? "Sorts into subfolders" : "Backs up, then sorts into subfolders"
        case .ignore: return "Leaves matches in place and skips later rules"
        }
    }

    private func scheduleSummary(for rule: FolderAutomationRule, folderPaused: Bool) -> String {
        if !rule.enabled { return "Rule is off" }
        if !automation.available { return "Automation unavailable" }
        if automation.isAutomationPaused { return "Automation paused" }
        if folderPaused { return "Folder paused" }
        if automation.runsInBackground(rule.directories.source) {
            return model.folderAutomationService.status == .enabled ? "Runs after Quit" : "Background worker unavailable"
        }
        return "Runs while Andromeda is open"
    }

    private func reapplyTitle(for rule: FolderAutomationRule, paused: Bool) -> String {
        if !rule.enabled { return "Enable Rule to Reapply" }
        if !paused { return "Pause Folder to Reapply Rule" }
        if automation.isAutomationPaused { return "Resume Automation to Reapply Rule" }
        if automation.runsInBackground(rule.directories.source) { return "Turn Off After-Quit Rules to Reapply" }
        return "Review Previously Processed Files…"
    }

    private var ruleSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search rules", text: $ruleSearch)
                .textFieldStyle(.roundedBorder)
            if !ruleSearch.isEmpty {
                Button("Clear rule search", systemImage: "xmark.circle.fill") { ruleSearch = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
        }
    }

    static func filteredRules(_ rules: [FolderAutomationRule], query: String) -> [FolderAutomationRule] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return rules }
        func contains(_ field: String?) -> Bool { field?.localizedStandardContains(term) == true }
        func matchesCondition(_ group: FolderAutomationRule.ConditionGroup) -> Bool {
            let fields = [group.pattern, group.fileExtension.map { ".\($0)" }, group.contentsContains,
                          group.fileKind?.folderName, group.minimumBytes.map { ByteFormat.string($0) },
                          group.maximumBytes.map { ByteFormat.string($0) },
                          group.minimumAgeDays.map { "\(group.ageBasis.title) \($0) days" },
                          group.maximumAgeDays.map { "\(group.ageBasis.title) \($0) days" }]
            return fields.contains(where: contains) || group.finderTags.contains(where: contains)
                || group.groups.contains(where: matchesCondition)
        }
        return rules.filter { rule in
            let fields = [rule.directories.source.path, rule.directories.destination.path,
                          AutomationRuleAction(rule).rawValue, rule.renamePrefix, rule.renameTemplate?.pattern,
                          rule.subfolderTemplate.map { "Sort into \($0.pattern)" },
                          rule.includedSubfolderPattern, rule.excludedSubfolderPattern]
            return fields.contains(where: contains) || matchesCondition(rule.conditionGroup)
                || rule.backupFolders.contains { contains("Back up to \($0.path)") }
                || (rule.excludedFinderTags + rule.copyFinderTags + rule.removedCopyTags).contains(where: contains)
                || rule.copyTagTemplates.contains { contains($0.pattern) }
        }
    }

    private var runtimeSettings: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Open Andromeda at login", isOn: Binding(
                get: { loginItem.isRegistered },
                set: { value in Task { await loginItem.setRegistered(value) } }
            ))
            .disabled(loginItem.isChanging || loginItem.status == .unavailable)
            if loginItem.status == .requiresApproval {
                HStack {
                    Text("Approve Andromeda in Login Items to open it at login.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open Login Items…") { loginItem.openSystemSettings() }
                }
            } else if loginItem.status == .unavailable {
                Text("Login item registration is unavailable for this copy of Andromeda.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = loginItem.problem {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            backgroundAutomationSetting
            if let showsAutomationMenu {
                Toggle("Show automation controls in the menu bar", isOn: showsAutomationMenu)
            }
            Toggle("Pause folder automation", isOn: Binding(
                get: { automation.isAutomationPaused },
                set: { problem = automation.setAutomationPaused($0) }
            ))
            .disabled(!automation.available)
        }
    }

    @ViewBuilder
    private var backgroundAutomationSetting: some View {
        let service = model.folderAutomationService
        if service.status != .unavailable || service.isEnabled {
            Toggle("Keep eligible rules running after Quit", isOn: Binding(
                get: { service.isEnabled },
                set: { value in Task { await service.setEnabled(value) } }
            ))
            .disabled(service.isChanging || (!service.isEnabled && !service.canEnable))
            Text(service.canEnable || service.isEnabled
                 ? "Supported Copy to Folder and Ignore rules run on your home APFS volume. Rules can include subfolders and match or skip Finder tags. Copy rules can also change tags on the copies. Folders with other enabled rules run while Andromeda is open."
                 : "Add a supported rule in an ordinary folder on your home APFS volume to use background automation.")
                .font(.caption).foregroundStyle(.secondary)
            if automation.backgroundTagMatchingNeedsOptIn {
                Text("To match Finder tags after Quit, turn this setting off and back on.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if service.status == .requiresApproval {
                HStack {
                    Text("Approve Andromeda in Login Items, then turn on this setting.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open Login Items…") { service.openSystemSettings() }
                }
            } else if service.status == .enabled && !service.isEnabled {
                Text("Turn on this setting to start the approved background worker.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if service.status != .enabled && service.isEnabled {
                Text("macOS has stopped the worker. Turn off this setting to resume eligible rules while Andromeda is open.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if service.isRegistered && !service.isEnabled {
                Button("Cancel Background Setup") { Task { await service.setEnabled(false) } }
                    .disabled(service.isChanging)
            }
            if let message = service.problem {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private static func tagSummary(_ tags: [String]) -> String {
        tags.map { "“\($0)”" }.joined(separator: ", ")
    }
}

private enum AutomationRuleAction: String, CaseIterable {
    case move = "Move to Folder"
    case copyThenMove = "Back Up, Then Move"
    case copy = "Copy to Folder"
    case rename = "Rename in Place"
    case sort = "Sort into Subfolders"
    case ignore = "Ignore Matching Files"

    init(_ rule: FolderAutomationRule?) {
        if rule?.ignoresMatches == true { self = .ignore }
        else if rule?.copiesMatches == true { self = .copy }
        else if rule?.renamesInPlace == true { self = .rename }
        else if let rule, rule.directories.source == rule.directories.destination { self = .sort }
        else { self = rule?.backupFolder == nil ? .move : .copyThenMove }
    }
}

struct AutomationRuleSheet: View {
    let model: AppModel
    let rule: FolderAutomationRule?
    let dismiss: () -> Void
    @Environment(\.pageIsScrollable) private var scrollable
    @State private var fields: Fields
    @State private var working = false
    @State private var problem: String?
    @State private var preview: FolderAutomationModel.Preview?
    @State private var previewFile: FilePreviewSelection?
    @State private var filePreviewTask: Task<Void, Never>?
    @State private var revealFilePreview = false
    @State private var showsAdvancedOptions: Bool
    @State private var showsExcludedTags: Bool
    @State private var showsSubfolderFilters: Bool
    @State private var showsCopyTagRules: Bool

    private var ignoresMatches: Bool { fields.action == .ignore }
    private var usesDestination: Bool { fields.action == .move || fields.action == .copy || fields.action == .copyThenMove }
    private var canBackUpInPlace: Bool { fields.action == .rename || fields.action == .sort }
    private var usesBackup: Bool { fields.action == .copyThenMove || (canBackUpInPlace && fields.backsUpInPlace) }
    private var canTagCopies: Bool { fields.action == .copy || usesBackup }

    private struct FilePreviewSelection: Equatable {
        let url: URL
        let identity: FileIdentity
    }

    private struct Fields: Equatable {
        var source: URL?
        var destination: URL?
        var backups: [URL]
        var action: AutomationRuleAction
        var backsUpInPlace: Bool
        var numbersBackupConflicts: Bool
        var includesSubfolders: Bool
        var folderStructure: FolderAutomationRule.FolderStructure
        var maximumSubfolderDepth: String
        var includedSubfolderPattern: String
        var excludedSubfolderPattern: String
        var folderPattern: String
        var subfolderDateBasis: AutomationSubfolderTemplate.DateBasis
        var conditions: AutomationConditionDraft
        var excludedFinderTags: String
        var copyFinderTags: String
        var copyTagTemplates: String
        var removedCopyTags: String
        var skipsIdenticalCopies: Bool
        var copiesOnArrival: Bool
        var notifiesOnCompletion: Bool
        var renamePrefix: String
        var usesTemplate: Bool
        var templatePattern: String
        var collisionPolicy: FolderAutomationRule.CollisionPolicy
    }

    init(model: AppModel, rule: FolderAutomationRule?, dismiss: @escaping () -> Void) {
        self.model = model
        self.rule = rule
        self.dismiss = dismiss
        _showsAdvancedOptions = State(initialValue: rule != nil)
        _showsExcludedTags = State(initialValue: rule.map { !$0.excludedFinderTags.isEmpty } ?? false)
        _showsSubfolderFilters = State(initialValue: rule?.includedSubfolderPattern != nil || rule?.excludedSubfolderPattern != nil)
        _showsCopyTagRules = State(initialValue: rule.map { !$0.copyTagTemplates.isEmpty || !$0.removedCopyTags.isEmpty } ?? false)
        let usesWatchedFolder = rule.map { $0.directories.source == $0.directories.destination } ?? false
        _fields = State(initialValue: Fields(source: rule?.directories.source.url,
                                             destination: usesWatchedFolder ? nil : rule?.directories.destination.url,
                                             backups: rule?.backupFolders.map(\.url) ?? [],
                                             action: AutomationRuleAction(rule),
                                             backsUpInPlace: usesWatchedFolder && rule?.backupFolder != nil,
                                             numbersBackupConflicts: rule?.numbersBackupConflicts ?? false,
                                             includesSubfolders: rule?.includesSubfolders ?? false,
                                             folderStructure: rule?.folderStructure ?? .flat,
                                             maximumSubfolderDepth: rule?.maximumSubfolderDepth.map(String.init) ?? "",
                                             includedSubfolderPattern: rule?.includedSubfolderPattern ?? "",
                                             excludedSubfolderPattern: rule?.excludedSubfolderPattern ?? "",
                                             folderPattern: rule?.subfolderTemplate?.pattern ?? "",
                                             subfolderDateBasis: rule?.subfolderTemplate?.dateBasis ?? .modified,
                                             conditions: .init(rule?.conditionGroup),
                                             excludedFinderTags: rule?.excludedFinderTags.joined(separator: "\n") ?? "",
                                             copyFinderTags: rule?.copyFinderTags.joined(separator: "\n") ?? "",
                                             copyTagTemplates: rule?.copyTagTemplates.map(\.pattern).joined(separator: "\n") ?? "",
                                             removedCopyTags: rule?.removedCopyTags.joined(separator: "\n") ?? "",
                                             skipsIdenticalCopies: rule?.skipsIdenticalCopies ?? false,
                                             copiesOnArrival: rule?.copiesOnArrival ?? false,
                                             notifiesOnCompletion: rule?.notifiesOnCompletion ?? false,
                                             renamePrefix: rule?.renamePrefix ?? "",
                                             usesTemplate: rule?.renameTemplate != nil,
                                             templatePattern: rule?.renameTemplate?.pattern ?? "",
                                             collisionPolicy: rule?.collisionPolicy ?? .leaveInPlace))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(title: rule == nil ? "New Folder Rule" : "Edit Folder Rule",
                        symbol: "folder.badge.gearshape", tint: .indigo)
            if rule?.enabled == false {
                Text("This rule is disabled. Enable it from the rules list when ready.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if scrollable {
                ScrollViewReader { scroll in
                    ScrollView {
                        ruleFields.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: preview != nil) { _, showing in
                        if showing && (previewFile == nil || revealFilePreview) {
                            scroll.scrollTo("preview", anchor: .bottom)
                            revealFilePreview = false
                        }
                    }
                    .onChange(of: previewFile) { _, selected in
                        if selected != nil { scroll.scrollTo("preview", anchor: .bottom) }
                    }
                }
                .frame(maxHeight: 650)
            } else {
                ruleFields.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let problem {
                Text(problem).foregroundStyle(.red)
            } else if let requiredInput {
                Text(requiredInput).font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Button("Preview Matches") { submit(previewing: true) }.disabled(!ready)
                Button("Preview File…", action: choosePreviewFile).disabled(!ready)
                Spacer()
                Button("Cancel", role: .cancel, action: dismiss)
                Button(rule == nil ? "Enable Rule" : "Save Rule") { submit(previewing: false) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!ready)
            }
        }
        .task { await model.storageMonitor.refreshNotificationStatus() }
        .onChange(of: fields) { old, new in
            preview = nil
            problem = nil
            if old.source != new.source {
                clearFilePreview()
            } else {
                refreshFilePreview()
            }
        }
        .onChange(of: model.folderAutomation.rules) { refreshFilePreview() }
        .onDisappear { filePreviewTask?.cancel() }
        .disabled(working)
        .interactiveDismissDisabled(working)
        .padding(24)
        .frame(width: 490)
        .background(Palette.canvas)
    }

    private var ruleFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeading(title: "Where to Watch")
                LabeledContent("Watched folder") {
                    Button(fields.source.map { Copy.Scan.displayPath($0, home: model.scanHome) } ?? "Choose Folder…") {
                        Task { if let folder = await model.chooseStorageFolder() { fields.source = folder } }
                    }
                    .lineLimit(1).truncationMode(.middle)
                    .help(fields.source?.path ?? "Choose the folder to watch for matching files.")
                }
                if fields.action != .sort {
                    Toggle("Include Subfolders", isOn: $fields.includesSubfolders)
                        .onChange(of: fields.includesSubfolders) { _, includesSubfolders in
                            if !includesSubfolders && fields.folderStructure == .watchedFolder {
                                fields.folderStructure = .flat
                            }
                        }
                }
            }
            .card(padding: 12)
            VStack(alignment: .leading, spacing: 10) {
                SectionHeading(title: "Which Files Match?")
                AutomationConditionGroupEditor(group: $fields.conditions)
                DisclosureGroup("Skip Files with Finder Tags", isExpanded: $showsExcludedTags) {
                    tagEditor("Skip files tagged", text: $fields.excludedFinderTags)
                    Text("Enter one Finder tag per line. These tags apply to the whole rule.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !fields.conditions.hasInput && fields.conditions.matchMode != .none,
                   !fields.excludedFinderTags.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Any eligible file without one of these tags can match. Preview the matches before enabling this rule.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .card(padding: 12)
            actionFields.card(padding: 12)
            if let previewFile {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(preview?.focusedFile?.relativePath ?? previewFile.url.lastPathComponent)
                            .font(.headline).lineLimit(2).truncationMode(.middle)
                        Spacer()
                        Button("Clear Preview", action: clearFilePreview).buttonStyle(.borderless)
                    }
                    if let focused = preview?.focusedFile {
                        Text(fileMatchDescription(focused.match))
                            .foregroundStyle(.secondary)
                        if rule?.enabled == false {
                            Text("Preview assumes this rule is enabled.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(focused.conditionChecks.indices, id: \.self) { index in
                            AutomationConditionResultView(check: focused.conditionChecks[index])
                        }
                    } else if !ready {
                        Text("Complete the rule to preview this file.").foregroundStyle(.secondary)
                    } else if problem == nil {
                        ProgressView("Checking this file…").controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .id("preview")
            } else if let preview {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(preview.matches) matching \(preview.matches == 1 ? "file" : "files") here now").font(.headline)
                    if rule?.enabled == false {
                        Text("Preview assumes this rule is enabled.")
                            .foregroundStyle(.secondary)
                    }
                    if preview.earlierRuleMatches > 0 {
                        let count = preview.earlierRuleMatches
                        Text("\(count) other \(count == 1 ? "file matches" : "files match") an earlier rule first.")
                            .foregroundStyle(.secondary)
                        ForEach(preview.earlierRuleExamples, id: \.relativePath) { example in
                            Text(earlierRuleExample(example)).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    if preview.conflicts > 0 {
                        Text(fields.action == .copy ? "\(preview.conflicts) would be skipped due to name conflicts."
                             : "\(preview.conflicts) would stay in place due to name conflicts.")
                    }
                    if preview.backupConflicts > 0 {
                        Text("\(preview.backupConflicts) would stay in place because a backup filename is already taken.")
                    }
                    if preview.identicalCopies > 0 {
                        Text("\(preview.identicalCopies) \(preview.identicalCopies == 1 ? "file would" : "files would") be skipped because an identical copy already exists.")
                    }
                    if preview.namesTooLong > 0 {
                        Text("\(preview.namesTooLong) would stay in place because the new name is too long.")
                    }
                    if preview.namesUnavailable > 0 {
                        Text("\(preview.namesUnavailable) would stay in place because the template couldn’t produce a name.")
                    }
                    if preview.tagsUnavailable > 0 {
                        Text("\(preview.tagsUnavailable) would be skipped because a Finder tag couldn’t be generated.")
                    }
                    if preview.destinationsUnavailable > 0 {
                        Text("\(preview.destinationsUnavailable) would stay in place because their destinations are unavailable.")
                    }
                    if preview.preservesSubfolderStructure, !preview.names.isEmpty {
                        Text("The preview includes each file’s destination path.")
                    }
                    if !preview.copyFinderTags.isEmpty, !preview.names.isEmpty, preview.renderedCopyTags.isEmpty {
                        Text(usesBackup ? "Tags added to backups · \(preview.copyFinderTags.joined(separator: ", "))"
                             : "Tags added to copies · \(preview.copyFinderTags.joined(separator: ", "))")
                    }
                    if !preview.removedCopyTags.isEmpty, !preview.names.isEmpty {
                        Text(usesBackup ? "Tags removed from backups when present · \(preview.removedCopyTags.joined(separator: ", "))"
                             : "Tags removed from copies when present · \(preview.removedCopyTags.joined(separator: ", "))")
                    }
                    ForEach(preview.names, id: \.self) { name in
                        ForEach(preview.backupCopyPaths[name] ?? [], id: \.self) { backup in
                            Text("Backup copy · \(backup)").lineLimit(1).truncationMode(.middle)
                        }
                        Text(preview.destinationPaths[name].map { "\(name) → \($0)" } ?? name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let tags = preview.renderedCopyTags[name] {
                            Text(usesBackup ? "Backup tags · \(tags.joined(separator: ", "))"
                                 : "Tags · \(tags.joined(separator: ", "))").foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.callout)
                .id("preview")
            }
        }
    }

    private var actionFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(title: "What Happens to Matches?")
            Picker("Action", selection: $fields.action) {
                ForEach(AutomationRuleAction.allCases, id: \.self) { action in
                    Text(LocalizedStringKey(action.rawValue)).tag(action)
                }
            }
            .pickerStyle(.menu)
            Text(actionDescription)
                .font(.callout).foregroundStyle(.secondary)
            if canBackUpInPlace {
                Toggle(fields.action == .rename ? "Back Up Before Renaming" : "Back Up Before Sorting",
                       isOn: $fields.backsUpInPlace)
                    .help("Andromeda verifies every backup before renaming or sorting the original.")
            }
            if usesBackup {
                LabeledContent("Backup folders") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(fields.backups.indices, id: \.self) { index in
                            let folder = fields.backups[index]
                            HStack {
                                Text(folder.path).lineLimit(1).truncationMode(.middle)
                                    .help(folder.path)
                                Spacer()
                                Button("Move Backup Earlier", systemImage: "arrow.up") {
                                    fields.backups.swapAt(index, index - 1)
                                }
                                .labelStyle(.iconOnly)
                                .disabled(index == 0)
                                Button("Move Backup Later", systemImage: "arrow.down") {
                                    fields.backups.swapAt(index, index + 1)
                                }
                                .labelStyle(.iconOnly)
                                .disabled(index == fields.backups.count - 1)
                                Button("Remove Backup Folder", systemImage: "minus.circle") {
                                    fields.backups.remove(at: index)
                                }
                                .labelStyle(.iconOnly)
                            }
                            .buttonStyle(.borderless)
                        }
                        Button(fields.backups.isEmpty ? "Choose Folder…" : "Add Backup Folder…") {
                            Task {
                                guard let folder = await model.chooseStorageFolder(),
                                      !fields.backups.contains(folder) else { return }
                                fields.backups.append(folder)
                            }
                        }
                    }
                }
                .help("Andromeda copies in this order. Each backup uses the original filename and relative folder path.")
                Toggle("Number New Backups on Name Conflicts", isOn: $fields.numbersBackupConflicts)
                    .help("If a backup name is occupied, use the next available name, such as Invoice 2.pdf. Existing backups stay in place.")
            }
            if usesDestination {
                LabeledContent(fields.action == .copy ? "Copy to" : "Move to") {
                    Button(fields.destination.map { Copy.Scan.displayPath($0, home: model.scanHome) } ?? "Choose Folder…") {
                        Task { if let folder = await model.chooseStorageFolder() { fields.destination = folder } }
                    }
                    .lineLimit(1).truncationMode(.middle)
                    .help(fields.destination?.path ?? "Choose where matching files will go.")
                }
                Picker("Folder Structure", selection: $fields.folderStructure) {
                    Text("Place files directly").tag(FolderAutomationRule.FolderStructure.flat)
                    Text("Immediate Parent").tag(FolderAutomationRule.FolderStructure.immediateParent)
                    if fields.includesSubfolders {
                        Text("From Watched Folder").tag(FolderAutomationRule.FolderStructure.watchedFolder)
                    }
                }
                .help("Recreates the selected folder structure under the destination. The subfolder pattern, if set, is added inside it.")
                if fields.includesSubfolders {
                    Text("Choose a destination outside the watched folder.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if fields.action == .sort { subfolderPatternFields }
            if fields.action == .rename { filenameOptions }
            if !ignoresMatches {
                Picker("If the destination name is taken", selection: $fields.collisionPolicy) {
                    Text(fields.action == .copy ? "Skip Copy" : "Leave in Place").tag(FolderAutomationRule.CollisionPolicy.leaveInPlace)
                    Text("Add a Number").tag(FolderAutomationRule.CollisionPolicy.numberIncoming)
                }
                .help("Adds a number before the extension, such as Invoice 2.pdf.")
            }
            if !ignoresMatches || fields.includesSubfolders {
                DisclosureGroup("Advanced Rule Options", isExpanded: $showsAdvancedOptions) {
                    advancedRuleFields.padding(.top, 8)
                }
            }
        }
    }

    private var advancedRuleFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            if fields.action != .sort && fields.includesSubfolders {
                LabeledContent("Maximum Subfolder Depth") {
                    TextField("Maximum Subfolder Depth", text: $fields.maximumSubfolderDepth, prompt: Text("No limit"))
                        .frame(width: 100)
                }
                .help("Use 1 to include only the folders directly inside the watched folder.")
                subfolderFilters
            }
            if usesDestination { subfolderPatternFields }
            if !ignoresMatches && fields.action != .rename { filenameOptions }
            if fields.action == .copy {
                Toggle("Copy When Files Arrive Complete", isOn: $fields.copiesOnArrival)
                    .help("Skip the settling wait during automatic copies. Use only for folders where files arrive complete.")
                if fields.copiesOnArrival {
                    Text("Use only when the app or script writing the file closes it before the rule can match it. For example, write to a temporary name, then rename it to the matching name after closing it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Skip Identical Copies", isOn: $fields.skipsIdenticalCopies)
                    .help("Skip matching file contents at the intended name. Add a Number also checks existing numbered copies. Existing files and tags stay in place.")
            }
            if canTagCopies {
                let addLabel = usesBackup ? "Add Finder Tags to Backups" : "Add Finder Tags to Copies"
                let removeLabel = usesBackup ? "Remove Tags From Backups" : "Remove Tags From Copies"
                LabeledContent(addLabel) {
                    tagEditor(addLabel, text: $fields.copyFinderTags)
                }
                .help("Enter one Finder tag per line. The original keeps its tags.")
                DisclosureGroup(usesBackup ? "Backup Tag Rules" : "Copy Tag Rules", isExpanded: $showsCopyTagRules) {
                    LabeledContent("Generate Tags From File Details") {
                        tagEditor("Generate Tags From File Details", text: $fields.copyTagTemplates)
                    }
                    Text("Use one pattern per line. {name} is the filename without its extension. {created} and {modified} are dates.")
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent(removeLabel) {
                        tagEditor(removeLabel, text: $fields.removedCopyTags)
                    }
                    .help("Enter one tag per line. Andromeda removes these tags from the copy before adding new tags.")
                }
            }
            if !ignoresMatches {
                Toggle("Notify after organizing files", isOn: $fields.notifiesOnCompletion)
                    .help("Shows a macOS notification with the number of files Andromeda finished. No file names or paths are shown.")
                if fields.notifiesOnCompletion {
                    switch model.storageMonitor.notificationStatus {
                    case .needsPermission:
                        Button("Enable macOS Notifications") {
                            Task { await model.storageMonitor.requestSystemNotificationPermission() }
                        }
                    case .denied:
                        SettingsNotificationsLink()
                    case .allowed, .unavailable:
                        EmptyView()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var subfolderPatternFields: some View {
        TextField("Subfolder pattern", text: $fields.folderPattern,
                  prompt: Text(usesDestination ? "Optional, e.g. {year}/{month}" : "Invoices/{year}/{month}"))
            .accessibilityLabel("Subfolder pattern")
        if fields.action == .sort || !fields.folderPattern.isEmpty {
            Text("Use / for folder levels, {name} for the filename stem, or {year}, {month}, and {day} for the file date.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if AutomationSubfolderTemplate.usesDate(in: fields.folderPattern) {
            Picker("Date for Subfolders", selection: $fields.subfolderDateBasis) {
                Text("Last Modified").tag(AutomationSubfolderTemplate.DateBasis.modified)
                Text("Date Created").tag(AutomationSubfolderTemplate.DateBasis.created)
                Text("Date Added").tag(AutomationSubfolderTemplate.DateBasis.added)
            }
            if fields.subfolderDateBasis != .modified {
                Text(fields.subfolderDateBasis == .created ? "Files without a creation date stay in place."
                     : "Files without a Date Added, including hard links, stay in place.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func earlierRuleExample(_ example: FolderAutomationRule.EarlierRuleMatch) -> String {
        guard let earlier = model.folderAutomation.rules.first(where: { $0.id == example.ruleID }) else {
            return example.relativePath
        }
        let action = AutomationRuleAction(earlier).rawValue
        let condition = earlier.pattern.isEmpty
            ? earlier.fileExtension.map { ".\($0)" } ?? earlier.finderTag ?? earlier.fileKind?.folderName
            : earlier.pattern
        return "\(example.relativePath) → \(action)" + (condition.map { " · \($0)" } ?? "")
    }

    private var subfolderFilters: some View {
        DisclosureGroup("Subfolder Filters", isExpanded: $showsSubfolderFilters) {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Include Names Matching") {
                    TextField("Include Names Matching", text: $fields.includedSubfolderPattern, prompt: Text("All names"))
                }
                LabeledContent("Skip Names Matching") {
                    TextField("Skip Names Matching", text: $fields.excludedSubfolderPattern, prompt: Text("None"))
                }
                Text("Each folder along the path must pass both filters. Use * or ? as wildcards.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        }
    }

    private func tagEditor(_ label: String, text: Binding<String>) -> some View {
        TextEditor(text: text)
            .font(.body)
            .accessibilityLabel(label)
            .frame(width: 225, height: 45)
            .scrollContentBackground(.hidden)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.hairline).allowsHitTesting(false))
    }

    @ViewBuilder
    private var filenameOptions: some View {
        Picker("Filenames", selection: $fields.usesTemplate) {
            Text("Add Prefix").tag(false)
            Text("Use Template").tag(true)
        }
        .pickerStyle(.segmented)
        if fields.usesTemplate {
            TextField("Filename template", text: $fields.templatePattern, prompt: Text("{modified} - {name}"))
                .accessibilityLabel("Filename template")
            Text("Use {name}, {created}, or {modified}. Dates use YYYY-MM-DD and the time zone saved with the rule. The file keeps its extension.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            LabeledContent("Filename prefix") {
                TextField("Filename prefix", text: $fields.renamePrefix,
                          prompt: Text(fields.action == .rename ? "Required" : "Optional"))
                    .labelsHidden()
                    .help("Keeps the original filename and extension after the prefix.")
            }
        }
    }

    private var actionDescription: String {
        switch fields.action {
        case .ignore:
            "Leave matching files in place and skip later rules for them. Use Move Earlier to give this rule priority."
        case .rename:
            "Matching files are renamed after they settle."
        case .copy:
            fields.copiesOnArrival
                ? "Automatic copies skip the settling wait. Use this only when files are complete before they match. Originals stay in the watched folder."
                : "Matching files are copied after they settle. The originals stay in the watched folder."
        case .copyThenMove:
            "Andromeda verifies every backup copy before moving each matching file."
        case .move, .sort:
            "Enabling this rule moves existing and new matching files after they settle."
        }
    }

    private var ready: Bool { requiredInput == nil }

    private var requiredInput: String? {
        if fields.source == nil { return "Choose the folder this rule should watch." }
        if usesDestination, fields.destination == nil { return "Choose a destination folder." }
        if usesBackup, fields.backups.isEmpty { return "Choose at least one backup folder." }
        if fields.action == .sort, fields.folderPattern.isEmpty { return "Enter a subfolder pattern." }
        if !ignoresMatches, fields.usesTemplate, fields.templatePattern.isEmpty {
            return fields.action == .rename || showsAdvancedOptions
                ? "Enter a filename template." : "Enter a filename template in Advanced Rule Options."
        }
        if fields.action == .rename, !fields.usesTemplate, fields.renamePrefix.isEmpty { return "Enter a filename prefix." }
        let hasCondition = fields.conditions.hasInput || (fields.conditions.matchMode != .none
            && !fields.excludedFinderTags.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        return hasCondition ? nil : "Add a match condition, such as a file extension."
    }

    private func fileMatchDescription(_ match: FolderAutomationRule.FileMatch) -> String {
        switch match {
        case .matches: return "This file matches the rule’s conditions."
        case .earlierRule: return "This file matches, but an earlier rule takes priority."
        case .doesNotMatch: return "This rule’s conditions did not match the file."
        case .unavailable: return "This file is outside the rule’s scope or unavailable for automation."
        }
    }

    private func choosePreviewFile() {
        guard let source = fields.source else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = source
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.canCreateDirectories = false
        panel.resolvesAliases = false
        panel.prompt = "Preview"
        guard panel.runModal() == .OK, let file = panel.url else { return }
        let root = SafetyGuard.withoutSystemPathAlias(source.standardizedFileURL.path)
        let path = SafetyGuard.withoutSystemPathAlias(file.standardizedFileURL.path)
        guard path.hasPrefix(root + "/") else {
            clearFilePreview()
            problem = "Choose a file inside the watched folder."
            return
        }
        guard let identity = FileIdentity(path: path) else {
            clearFilePreview()
            problem = "The selected file is no longer available."
            return
        }
        previewFile = FilePreviewSelection(url: file, identity: identity)
        revealFilePreview = true
        refreshFilePreview()
    }

    private func clearFilePreview() {
        filePreviewTask?.cancel()
        previewFile = nil
        revealFilePreview = false
        preview = nil
        problem = nil
    }

    private func refreshFilePreview() {
        guard let file = previewFile else { return }
        let previous = filePreviewTask
        previous?.cancel()
        preview = nil
        problem = nil
        filePreviewTask = Task {
            // An OCR read can already be in progress. Let it finish before checking the latest edit.
            await previous?.value
            do { try await Task.sleep(for: .milliseconds(200)) }
            catch { return }
            guard !Task.isCancelled, previewFile == file else { return }
            await runSubmission(previewing: true, focusedFile: file)
        }
    }

    private func submit(previewing: Bool) {
        if previewing { clearFilePreview() }
        else { filePreviewTask?.cancel() }
        Task { await runSubmission(previewing: previewing) }
    }

    private func runSubmission(previewing: Bool, focusedFile: FilePreviewSelection? = nil) async {
        guard !working, let source = fields.source, ready else { return }
        let destination = usesDestination ? fields.destination : nil
        let backups = usesBackup ? fields.backups : []
        problem = nil
        preview = nil
        let conditions: FolderAutomationRule.ConditionGroup
        do {
            conditions = try fields.conditions.condition(allowEmpty: fields.conditions.matchMode != .none)
        } catch {
            problem = error.localizedDescription
            return
        }
        let includesSubfolders = fields.action != .sort && fields.includesSubfolders
        let folderStructure: FolderAutomationRule.FolderStructure = usesDestination && (includesSubfolders || fields.folderStructure == .immediateParent)
            ? fields.folderStructure : .flat
        let depth = fields.maximumSubfolderDepth.trimmingCharacters(in: .whitespacesAndNewlines)
        let maximumSubfolderDepth = includesSubfolders ? Int(depth) : nil
        if includesSubfolders, !depth.isEmpty, (maximumSubfolderDepth ?? 0) <= 0 {
            problem = "Enter a whole number of 1 or more for the maximum subfolder depth."
            return
        }
        let includedSubfolderPattern = includesSubfolders ? fields.includedSubfolderPattern : nil
        let excludedSubfolderPattern = includesSubfolders ? fields.excludedSubfolderPattern : nil
        guard FolderAutomationRule.isValidSubfolderPattern(includedSubfolderPattern),
              FolderAutomationRule.isValidSubfolderPattern(excludedSubfolderPattern) else {
            problem = "Enter a folder name pattern without slashes or control characters."
            return
        }
        let excludedFinderTags = fields.excludedFinderTags.components(separatedBy: .newlines)
        let copyFinderTags = canTagCopies ? fields.copyFinderTags.components(separatedBy: .newlines) : []
        let removedCopyTags = canTagCopies ? fields.removedCopyTags.components(separatedBy: .newlines) : []
        let tagPatterns = canTagCopies ? fields.copyTagTemplates.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } : []
        let copyTagTemplates = tagPatterns.compactMap { pattern in
            rule?.copyTagTemplates.first { $0.pattern == pattern } ?? AutomationFinderTagTemplate(pattern)
        }
        guard tagPatterns.count == copyTagTemplates.count else {
            problem = "Use {name}, {created}, or {modified} in tag patterns."
            return
        }
        let skipsIdenticalCopies = fields.action == .copy && fields.skipsIdenticalCopies
        let copiesOnArrival = fields.action == .copy && fields.copiesOnArrival
        guard (excludedFinderTags + copyFinderTags + removedCopyTags).allSatisfy({ FolderAutomationRule.isValidFinderTag($0) }) else {
            problem = "Enter Finder tag names without control characters."
            return
        }
        let renamePrefix = ignoresMatches || fields.usesTemplate || fields.renamePrefix.isEmpty ? nil : fields.renamePrefix
        guard FolderAutomationRule.isValidRenamePrefix(renamePrefix) else {
            problem = "Use a short prefix without a leading dot, slashes, colons, or control characters."
            return
        }
        let renameTemplate: AutomationFilenameTemplate?
        if !ignoresMatches, fields.usesTemplate {
            if let saved = rule?.renameTemplate, saved.pattern == fields.templatePattern {
                renameTemplate = saved
            } else {
                guard let template = AutomationFilenameTemplate(fields.templatePattern) else {
                    problem = "Use only the listed tokens and filename text without a leading dot, slashes, or colons."
                    return
                }
                renameTemplate = template
            }
        } else {
            renameTemplate = nil
        }
        let subfolderTemplate: AutomationSubfolderTemplate?
        if (usesDestination || fields.action == .sort), !fields.folderPattern.isEmpty {
            let template: AutomationSubfolderTemplate?
            if let saved = rule?.subfolderTemplate, saved.pattern == fields.folderPattern {
                template = saved.usingDateBasis(fields.subfolderDateBasis)
            } else {
                template = AutomationSubfolderTemplate(fields.folderPattern, dateBasis: fields.subfolderDateBasis)
            }
            guard let template else {
                problem = "Enter folder names and the listed tokens, separated by /."
                return
            }
            subfolderTemplate = template
        } else {
            subfolderTemplate = nil
        }
        let locksEditor = focusedFile == nil
        if locksEditor { working = true }
        defer { if locksEditor { working = false } }
        let ignore = ignoresMatches
        let copy = fields.action == .copy
        let collisionPolicy = fields.collisionPolicy
        let numbersBackupConflicts = usesBackup && fields.numbersBackupConflicts
        if previewing {
            let submittedFields = fields
            let result = await model.folderAutomation.preview(
                source: source, destination: destination, backup: backups.first,
                additionalBackups: Array(backups.dropFirst()), pattern: conditions.pattern,
                fileExtension: conditions.fileExtension,
                minimumBytes: conditions.minimumBytes, maximumBytes: conditions.maximumBytes,
                minimumAgeDays: conditions.minimumAgeDays, maximumAgeDays: conditions.maximumAgeDays,
                ageBasis: conditions.ageBasis,
                fileKind: conditions.fileKind, finderTags: conditions.finderTags,
                excludedFinderTags: excludedFinderTags, matchMode: conditions.matchMode,
                contentsContains: conditions.contentsContains, recognizesText: conditions.recognizesText,
                conditionGroups: conditions.groups,
                renamePrefix: renamePrefix, renameTemplate: renameTemplate,
                subfolderTemplate: subfolderTemplate, ignoresMatches: ignore,
                copiesMatches: copy, copyFinderTags: copyFinderTags,
                copyTagTemplates: copyTagTemplates, removedCopyTags: removedCopyTags,
                skipsIdenticalCopies: skipsIdenticalCopies, copiesOnArrival: copiesOnArrival,
                includesSubfolders: includesSubfolders,
                maximumSubfolderDepth: maximumSubfolderDepth,
                folderStructure: folderStructure,
                includedSubfolderPattern: includedSubfolderPattern,
                excludedSubfolderPattern: excludedSubfolderPattern,
                collisionPolicy: collisionPolicy,
                numbersBackupConflicts: numbersBackupConflicts,
                editing: rule?.id, focusedFile: focusedFile?.url, focusedFileIdentity: focusedFile?.identity
            )
            guard !Task.isCancelled, submittedFields == fields, focusedFile == previewFile else { return }
            preview = result
            if result == nil { problem = "Check the approved folders, rule conditions, and History." }
        } else {
            problem = await model.folderAutomation.add(
                source: source, destination: destination, backup: backups.first,
                additionalBackups: Array(backups.dropFirst()), pattern: conditions.pattern,
                fileExtension: conditions.fileExtension,
                minimumBytes: conditions.minimumBytes, maximumBytes: conditions.maximumBytes,
                minimumAgeDays: conditions.minimumAgeDays, maximumAgeDays: conditions.maximumAgeDays,
                ageBasis: conditions.ageBasis,
                fileKind: conditions.fileKind, finderTags: conditions.finderTags,
                excludedFinderTags: excludedFinderTags, matchMode: conditions.matchMode,
                contentsContains: conditions.contentsContains, recognizesText: conditions.recognizesText,
                conditionGroups: conditions.groups,
                renamePrefix: renamePrefix, renameTemplate: renameTemplate,
                subfolderTemplate: subfolderTemplate, ignoresMatches: ignore,
                copiesMatches: copy, copyFinderTags: copyFinderTags,
                copyTagTemplates: copyTagTemplates, removedCopyTags: removedCopyTags,
                skipsIdenticalCopies: skipsIdenticalCopies, copiesOnArrival: copiesOnArrival,
                includesSubfolders: includesSubfolders,
                maximumSubfolderDepth: maximumSubfolderDepth,
                folderStructure: folderStructure,
                includedSubfolderPattern: includedSubfolderPattern,
                excludedSubfolderPattern: excludedSubfolderPattern,
                collisionPolicy: collisionPolicy,
                numbersBackupConflicts: numbersBackupConflicts,
                notifiesOnCompletion: fields.notifiesOnCompletion && !ignore,
                editing: rule?.id
            )
            if problem == nil { dismiss() }
        }
    }
}

private struct AutomationConditionResultView: View {
    let check: FolderAutomationRule.ConditionCheck

    private var status: (title: String, symbol: String, color: Color) {
        switch check.result {
        case true?: return ("Matched", "checkmark.circle.fill", .green)
        case false?: return ("Didn’t match", "xmark.circle", .secondary)
        case nil: return ("Couldn’t check", "questionmark.circle", .orange)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: status.symbol)
                    .foregroundStyle(status.color)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(check.label)
                    if let value = check.value {
                        Text(value).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 6)
                Text(status.title).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            ForEach(check.children.indices, id: \.self) { index in
                AutomationConditionResultView(check: check.children[index]).padding(.leading, 12)
            }
        }
        .font(.callout)
    }
}

extension FolderAutomationRule.AgeBasis {
    var title: String {
        switch self {
        case .modified: "Last Modified"
        case .created: "Date Created"
        case .added: "Date Added"
        case .opened: "Last Opened"
        }
    }
}
