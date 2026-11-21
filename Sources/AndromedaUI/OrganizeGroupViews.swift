import AppKit
import AndromedaAppModel
import AndromedaOrganize
import SwiftUI

/// Organize 3a: the Groups section of the folder review. One card per group (tick, name, reasons,
/// counts, its files), the parent suggestions, and the two bulk actions (Keep together, Put in one folder).
struct OrganizeGroupsSection: View {
    let review: OrganizeReview
    let folder: FolderOrganizeModel
    let flow: OrganizeFlow
    @State private var sheet: GroupSheetKind?
    /// Why a parent suggestion couldn't be applied, by its name.
    @State private var suggestionProblems: [String: String] = [:]

    /// Cards whose files all went to Unsorted show their reason there instead, unless the card offers a
    /// choice of folders (the user can still choose another).
    private var cards: [OrganizeGroupCard] { review.groups.filter { $0.count > 0 || !$0.choices.isEmpty } }
    /// The name groups: the ones that can be kept together or put in one folder (not a your-folder group, a
    /// rule's or Move to…'s).
    private var nameCards: [OrganizeGroupCard] { cards.filter { !$0.isYourFolder && !$0.isPlacedByYou } }

    var body: some View {
        if !cards.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeading(title: Copy.Organize.groupsTitle)
                let rowsByGroup = Dictionary(grouping: review.rows.filter { $0.groupID != nil }, by: { $0.groupID! })
                InsetGroup { ForEach(cards) { card in
                    GroupCardView(
                        card: card, rows: rowsByGroup[card.id] ?? [],
                        onToggle: { flow.toggleGroup(id: card.id) },
                        onRename: { name in await folder.renameGroup(id: card.id, to: name) },
                        onRemove: { rowID in Task { await folder.removeFromGroup(rowID: rowID) } },
                        onToggleRow: { id in flow.toggle(stepID: id) },
                        onChoose: { path in Task { await folder.chooseDestination(groupID: card.id, path: path) } },
                        onRemember: { await folder.rememberGroup(id: card.id) },
                        onMoveTo: { rowID in await MoveToPanel.move(rowID: rowID, folder: folder) })
                } }
                ForEach(review.parentSuggestions, id: \.name) { suggestion in
                    HStack(spacing: 8) {
                        Image(systemName: "lightbulb").foregroundStyle(Color.accentColor)
                        Text(Copy.Organize.parentSuggestionLine(suggestion.name, groups: suggestion.groupIDs.count))
                            .font(.callout)
                        Button(Copy.Organize.applySuggestion) {
                            Task { suggestionProblems[suggestion.name] = await folder.applyParentSuggestion(suggestion) }
                        }
                        .accessibilityLabel(Copy.Organize.parentSuggestionLine(suggestion.name, groups: suggestion.groupIDs.count)
                                            + ", " + Copy.Organize.applySuggestion)
                        if let problem = suggestionProblems[suggestion.name] {
                            Text(problem).font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                if !nameCards.isEmpty {
                    HStack(spacing: 8) {
                        if nameCards.count > 1 {
                            Button(Copy.Organize.keepTogether) { sheet = .merge }
                                .accessibilityLabel(Copy.Organize.keepTogether)
                        }
                        Button(Copy.Organize.putInOneFolder) { sheet = .nest }
                            .accessibilityLabel(Copy.Organize.putInOneFolder)
                    }
                }
            }
            .disabled(folder.isPlanning || flow.isApplying)
            .sheet(item: $sheet) { kind in
                GroupPickSheet(
                    kind: kind, cards: nameCards, suggestedName: review.parentSuggestions.first?.name ?? "",
                    onCancel: { sheet = nil },
                    onMerge: { ids in Task { await folder.mergeGroups(ids); sheet = nil } },
                    onNest: { ids, name in await folder.nest(ids, under: name) },
                    onDone: { sheet = nil })
            }
        }
    }
}

enum GroupSheetKind: String, Identifiable {
    case merge, nest
    var id: String { rawValue }
}

private struct GroupCardView: View {
    let card: OrganizeGroupCard
    let rows: [OrganizeReviewRow]
    let onToggle: () -> Void
    let onRename: (String) async -> String?
    let onRemove: (UUID) -> Void
    let onToggleRow: (UUID) -> Void
    let onChoose: (String) -> Void
    let onRemember: () async -> String?
    /// Move to… on one of the card's rows: nil when moved or cancelled, else why not.
    let onMoveTo: (UUID) async -> String?
    @State private var renaming = false
    @State private var draft = ""
    @State private var problem: String?
    @State private var expanded = false

    private var label: String {
        Copy.Organize.groupCardLabel(card.name, ticked: card.tickedCount, count: card.count, suggestion: card.isSuggestion)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // On only when every row is ticked; a click then ticks all unless all are ticked.
                Toggle(Copy.Organize.includeGroup(card.name),
                       isOn: Binding(get: { card.tickedCount == card.count }, set: { _ in onToggle() }))
                    .toggleStyle(.checkbox).labelsHidden()
                    .accessibilityLabel(Copy.Organize.includeGroup(card.name))
                if renaming {
                    TextField(Copy.Organize.nameThisGroup, text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(Copy.Organize.nameThisGroup)
                        .onSubmit { Task { await submit() } }
                } else {
                    Image(systemName: card.isYourFolder ? "folder.fill.badge.person.crop" : "folder.fill")
                        .foregroundStyle(card.isSuggestion ? Color.secondary : Color.accentColor)
                        .accessibilityHidden(true)
                    Text(card.name).font(.body.weight(.semibold))
                    // An existing folder of the user's is not renamed here, nor a rule's or Move to…'s.
                    if !card.isYourFolder && !card.isPlacedByYou { renameButton }
                    if card.canRemember { rememberMenu }
                }
                ForEach(card.reasons, id: \.self) { chip($0) }
                if card.isSuggestion { chip(Copy.Organize.suggestion, tint: .accentColor) }
                Spacer(minLength: 8)
                Text(Copy.Organize.tickedOfCount(card.tickedCount, card.count))
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            if !card.choices.isEmpty {
                Picker(Copy.Organize.chooseDestination, selection: Binding(get: { destination }, set: { onChoose($0) })) {
                    ForEach(card.choices, id: \.self) { Text($0).tag($0) }
                    Text(Copy.Organize.newFolderChoice).tag("")
                }
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityLabel(Copy.Organize.chooseDestination)
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.orange) }
            files
        }
        .groupRow()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    /// The picker's selection: the folder the rows go into when it is one of the choices, else a new folder.
    private var destination: String {
        guard let d = rows.first?.destination, card.choices.contains(d) else { return "" }
        return d
    }

    private var renameButton: some View {
        Button {
            draft = card.name
            problem = nil
            renaming = true
        } label: { Image(systemName: "pencil") }
            .buttonStyle(.plain)
            .accessibilityLabel(Copy.Organize.renameGroup)
    }

    private var rememberMenu: some View {
        Menu {
            Button(Copy.Organize.rememberThis) { Task { problem = await onRemember() } }
                .accessibilityLabel(Copy.Organize.rememberThisLabel(card.name))
        } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(Copy.Organize.rememberThisLabel(card.name))
    }

    private var files: some View {
        DisclosureGroup(Copy.Organize.showFiles, isExpanded: $expanded) {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(rows) { row in
                    HStack(spacing: 8) {
                        Toggle(row.name, isOn: Binding(get: { row.ticked }, set: { _ in onToggleRow(row.id) }))
                            .toggleStyle(.checkbox).labelsHidden()
                            .accessibilityLabel(row.name)
                        Text(row.name).font(.callout)
                        Spacer(minLength: 8)
                        Button(Copy.Organize.moveTo) { Task { problem = await onMoveTo(row.id) } }
                            .buttonStyle(.plain).font(.caption).foregroundStyle(Color.accentColor)
                            .accessibilityLabel(Copy.Organize.moveToLabel(row.name))
                        // A rule's or Move to…'s file isn't in a found group to leave.
                        if !card.isPlacedByYou {
                            Button(Copy.Organize.notInThisGroup) { onRemove(row.id) }
                                .buttonStyle(.plain).font(.caption).foregroundStyle(Color.accentColor)
                                .accessibilityLabel(Copy.Organize.notInThisGroup + ", " + row.name)
                        }
                    }
                }
            }
            .padding(.top, 4)
        }
        .font(.caption)
        .accessibilityLabel(Copy.Organize.filesIn(card.name))
    }

    private func submit() async {
        problem = await onRename(draft)
        if problem == nil { renaming = false }
    }

    private func chip(_ text: String, tint: Color? = nil) -> some View {
        Chip(text: text, tint: tint)
    }
}

/// Keep together / Put these in one folder: pick cards, and for the second, name the parent.
private struct GroupPickSheet: View {
    let kind: GroupSheetKind
    let cards: [OrganizeGroupCard]
    let onCancel: () -> Void
    let onMerge: ([String]) -> Void
    let onNest: ([String], String) async -> String?
    let onDone: () -> Void
    @State private var picked: Set<String> = []
    @State private var name: String
    @State private var problem: String?

    init(kind: GroupSheetKind, cards: [OrganizeGroupCard], suggestedName: String,
         onCancel: @escaping () -> Void, onMerge: @escaping ([String]) -> Void,
         onNest: @escaping ([String], String) async -> String?, onDone: @escaping () -> Void) {
        self.kind = kind
        self.cards = cards
        self.onCancel = onCancel
        self.onMerge = onMerge
        self.onNest = onNest
        self.onDone = onDone
        _name = State(initialValue: suggestedName)
    }

    private var title: String { kind == .merge ? Copy.Organize.keepTogether : Copy.Organize.putInOneFolder }
    private var ids: [String] { cards.map(\.id).filter { picked.contains($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.weight(.bold))
            ForEach(cards) { card in
                Toggle(card.name, isOn: Binding(
                    get: { picked.contains(card.id) },
                    set: { on in if on { picked.insert(card.id) } else { picked.remove(card.id) } }))
                    .toggleStyle(.checkbox)
                    .accessibilityLabel(Copy.Organize.groupCardLabel(
                        card.name, ticked: card.tickedCount, count: card.count, suggestion: card.isSuggestion))
            }
            if kind == .nest {
                TextField(Copy.Organize.nameThisGroup, text: $name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(Copy.Organize.nameThisGroup)
                if let problem { Text(problem).font(.caption).foregroundStyle(.orange) }
            }
            HStack {
                Spacer()
                Button(UICopy.cancel, action: onCancel).keyboardShortcut(.cancelAction)
                    .accessibilityLabel(UICopy.cancel)
                Button(title) {
                    if kind == .merge {
                        onMerge(ids)
                    } else {
                        Task {
                            problem = await onNest(ids, name)
                            if problem == nil { onDone() }
                        }
                    }
                }
                .disabled(ids.count < (kind == .merge ? 2 : 1))
                .accessibilityLabel(title)
            }
        }
        .padding(24)
        .frame(minWidth: 420)
        .background(Palette.canvas)
    }
}

/// **Move to…**: the open panel (folders only, starting at the picked folder, New Folder allowed) with a
/// **Remember this** checkbox below it. AppKit only, so it lives here; the model takes the URL and the flag.
@MainActor
enum MoveToPanel {
    /// Runs the panel for one move row and hands the choice to the folder model. Nil when cancelled.
    static func move(rowID: UUID, folder: FolderOrganizeModel) async -> String? {
        guard let (url, remember) = choose(startingAt: folder.folder) else { return nil }
        return await folder.moveRow(rowID: rowID, to: url, remember: remember)
    }

    static func choose(startingAt start: URL?) -> (URL, Bool)? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = start
        panel.prompt = Copy.Organize.moveTo
        let box = NSButton(checkboxWithTitle: Copy.Organize.rememberThis, target: nil, action: nil)
        box.setAccessibilityLabel(Copy.Organize.rememberThis)
        box.sizeToFit()
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: box.frame.width + 40, height: box.frame.height + 16))
        box.setFrameOrigin(NSPoint(x: 20, y: 8))
        accessory.addSubview(box)
        panel.accessoryView = accessory
        panel.isAccessoryViewDisclosed = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return (url, box.state == .on)
    }
}
