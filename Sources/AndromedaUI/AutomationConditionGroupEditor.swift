import AndromedaOrganize
import SwiftUI

struct AutomationConditionDraft: Identifiable, Equatable {
    let id = UUID()
    var matchMode: FolderAutomationRule.MatchMode
    var pattern: String
    var fileExtension: String
    var minimumMB: String
    var maximumMB: String
    var minimumDays: String
    var maximumDays: String
    var ageBasis: FolderAutomationRule.AgeBasis
    var fileKind: Kind?
    var finderTags: String
    var contentsContains: String
    var recognizesText: Bool
    var groups: [Self]

    init(_ saved: FolderAutomationRule.ConditionGroup? = nil) {
        matchMode = saved?.matchMode ?? .all
        pattern = saved?.pattern ?? ""
        fileExtension = saved?.fileExtension ?? ""
        minimumMB = saved?.minimumBytes.map(Self.megabytes) ?? ""
        maximumMB = saved?.maximumBytes.map(Self.megabytes) ?? ""
        minimumDays = saved?.minimumAgeDays.map(String.init) ?? ""
        maximumDays = saved?.maximumAgeDays.map(String.init) ?? ""
        ageBasis = saved?.ageBasis ?? .modified
        fileKind = saved?.fileKind
        finderTags = saved?.finderTags.joined(separator: "\n") ?? ""
        contentsContains = saved?.contentsContains ?? ""
        recognizesText = saved?.recognizesText ?? false
        groups = saved?.groups.map { Self($0) } ?? []
    }

    var hasInput: Bool {
        fileKind != nil || !groups.isEmpty
            || [pattern, fileExtension, minimumMB, maximumMB, minimumDays, maximumDays, finderTags, contentsContains]
                .contains { !Self.trim($0).isEmpty }
    }

    var hasAge: Bool { !Self.trim(minimumDays).isEmpty || !Self.trim(maximumDays).isEmpty }

    var hasMoreConditions: Bool {
        hasAge || [contentsContains, finderTags, minimumMB, maximumMB].contains { !Self.trim($0).isEmpty }
    }

    func condition(allowEmpty: Bool = false) throws -> FolderAutomationRule.ConditionGroup {
        let minSize = Self.trim(minimumMB), maxSize = Self.trim(maximumMB)
        let minAge = Self.trim(minimumDays), maxAge = Self.trim(maximumDays)
        let minimumBytes = Self.bytes(minSize), maximumBytes = Self.bytes(maxSize)
        let minimumAgeDays = Int(minAge), maximumAgeDays = Int(maxAge)
        let tags = finderTags.components(separatedBy: .newlines)
        let extensionCondition = Self.trim(fileExtension).isEmpty ? nil : fileExtension
        guard !pattern.contains("/") else { throw InputProblem("Enter a filename pattern without slashes.") }
        guard FolderAutomationRule.isValidFileExtension(extensionCondition) else {
            throw InputProblem("Enter a single file extension, such as pdf.")
        }
        guard tags.allSatisfy({ FolderAutomationRule.isValidFinderTag($0) }) else {
            throw InputProblem("Enter Finder tag names without control characters.")
        }
        guard minSize.isEmpty || minimumBytes != nil, maxSize.isEmpty || maximumBytes != nil else {
            throw InputProblem("Enter a nonnegative size in MB with up to six decimal places.")
        }
        guard minAge.isEmpty || minimumAgeDays.map({ (0...36_500).contains($0) }) == true,
              maxAge.isEmpty || maximumAgeDays.map({ (0...36_500).contains($0) }) == true else {
            throw InputProblem("Enter a whole number of days from 0 to 36,500.")
        }
        guard (minimumBytes ?? 0) <= (maximumBytes ?? .max) else {
            throw InputProblem("The maximum size must be at least the minimum size.")
        }
        guard (minimumAgeDays ?? 0) <= (maximumAgeDays ?? .max) else {
            throw InputProblem("The maximum age must be at least the minimum age.")
        }
        let children = try groups.map { try $0.condition() }
        let phrase = Self.trim(contentsContains)
        let group = FolderAutomationRule.ConditionGroup(
            matchMode: matchMode, pattern: pattern, fileExtension: extensionCondition,
            minimumBytes: minimumBytes, maximumBytes: maximumBytes,
            minimumAgeDays: minimumAgeDays, maximumAgeDays: maximumAgeDays, ageBasis: ageBasis,
            fileKind: fileKind, finderTags: tags, contentsContains: phrase.isEmpty ? nil : phrase,
            recognizesText: !phrase.isEmpty && recognizesText, groups: children)
        guard allowEmpty || group.hasConditions else { throw InputProblem("Add a condition to each group or remove the empty group.") }
        return group
    }

    private struct InputProblem: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private static func trim(_ input: String) -> String {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func bytes(_ size: String) -> Int64? {
        guard size.wholeMatch(of: /[0-9]+(\.[0-9]{1,6})?/) != nil,
              let megabytes = Decimal(string: size, locale: Locale(identifier: "en_US_POSIX")),
              megabytes <= Decimal(Int64.max) / 1_000_000 else { return nil }
        return NSDecimalNumber(decimal: megabytes * 1_000_000).int64Value
    }

    private static func megabytes(_ bytes: Int64) -> String {
        (NSDecimalNumber(value: bytes).decimalValue / 1_000_000).description
    }
}

struct AutomationConditionGroupEditor: View {
    @Binding var group: AutomationConditionDraft
    var remove: (() -> Void)?
    @State private var expanded = true
    @State private var showsMoreConditions: Bool

    init(group: Binding<AutomationConditionDraft>, remove: (() -> Void)? = nil) {
        _group = group
        self.remove = remove
        _showsMoreConditions = State(initialValue: group.wrappedValue.hasMoreConditions)
    }

    var body: some View {
        if let remove {
            DisclosureGroup(isExpanded: $expanded) {
                fields.padding(.leading, 10).padding(.vertical, 4)
            } label: {
                HStack {
                    Text(groupTitle).font(.callout.weight(.medium))
                    Spacer()
                    Button("Remove Condition Group", systemImage: "minus.circle", action: remove)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
            }
        } else {
            fields
        }
    }

    private var groupTitle: String {
        switch group.matchMode {
        case .all: "Match All in Group"
        case .any: "Match Any in Group"
        case .none: "Match None in Group"
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Match conditions", selection: $group.matchMode) {
                Text("All").tag(FolderAutomationRule.MatchMode.all)
                Text("Any").tag(FolderAutomationRule.MatchMode.any)
                Text("None").tag(FolderAutomationRule.MatchMode.none)
            }
            .pickerStyle(.segmented)
            .help("A group counts as one condition. None requires enough information to rule out every condition.")
            LabeledContent("Filename pattern") {
                TextField("Filename pattern", text: $group.pattern, prompt: Text("Optional, e.g. *.pdf"))
                    .accessibilityLabel("Filename pattern")
            }
            LabeledContent("File extension") {
                TextField("File extension", text: $group.fileExtension, prompt: Text("Optional, e.g. pdf"))
                    .accessibilityLabel("File extension")
                    .help("Matches the extension after the last dot, ignoring case. For archive.tar.gz, enter gz.")
            }
            Picker("File kind", selection: $group.fileKind) {
                Text("Any kind").tag(Kind?.none)
                ForEach(Kind.allCases, id: \.self) { kind in Text(kind.folderName).tag(Optional(kind)) }
            }
            .help("Uses the filename extension and standard screenshot names.")
            DisclosureGroup("More Conditions", isExpanded: $showsMoreConditions) {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Contents contain") {
                        TextField("Contents contain", text: $group.contentsContains, prompt: Text("Optional, e.g. invoice number"))
                            .accessibilityLabel("Contents contain")
                            .help("Searches supported plain-text files up to 4 MiB and selectable PDF text up to 16 MiB and 100 pages. Ignores case and accents.")
                    }
                    if !group.contentsContains.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Toggle("Recognize text in scans and images", isOn: $group.recognizesText)
                            .help("Looks for the phrase in supported images and up to eight PDF pages without selectable text. Recognition runs on this Mac. Unrecognized text cannot satisfy a None condition.")
                    }
                    LabeledContent("Finder tags") {
                        TextEditor(text: $group.finderTags)
                            .font(.body)
                            .accessibilityLabel("Finder tags")
                            .frame(width: 225, height: 45)
                            .scrollContentBackground(.hidden)
                            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.hairline).allowsHitTesting(false))
                            .help("Enter one tag per line. Each tag counts as one condition.")
                    }
                    HStack {
                        limitField("Minimum size (MB)", value: $group.minimumMB)
                        limitField("Maximum size (MB)", value: $group.maximumMB)
                    }
                    HStack {
                        limitField("Minimum age (days)", value: $group.minimumDays)
                        limitField("Maximum age (days)", value: $group.maximumDays)
                    }
                    if group.hasAge {
                        Picker("Measure age from", selection: $group.ageBasis) {
                            ForEach(FolderAutomationRule.AgeBasis.allCases, id: \.self) { basis in
                                Text(basis.title).tag(basis)
                            }
                        }
                        .help(group.ageBasis == .opened
                              ? "Uses the date recorded by Spotlight, when available. Each day is 24 hours."
                              : "Each day is 24 hours.")
                    }
                }
                .padding(.top, 6)
            }
            ForEach($group.groups) { $child in
                let id = child.id
                AutomationConditionGroupEditor(group: $child) { group.groups.removeAll { $0.id == id } }
            }
            Button("Add Condition Group", systemImage: "plus") { group.groups.append(.init()) }
        }
    }

    private func limitField(_ title: LocalizedStringKey, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: value, prompt: Text("Optional")).accessibilityLabel(Text(title))
        }
    }
}
