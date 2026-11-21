import AndromedaAppModel
import SwiftUI

struct CatalogNoteDraft: Identifiable {
    let id = UUID()
    var match: DriveCatalogMatch?
    var note: DriveCatalogNote?
}

struct CatalogNoteEditor: View {
    let drives: DrivesModel
    let draft: CatalogNoteDraft
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var tags: String
    @State private var problem: String?

    init(drives: DrivesModel, draft: CatalogNoteDraft) {
        self.drives = drives
        self.draft = draft
        _text = State(initialValue: draft.note?.text ?? "")
        _tags = State(initialValue: draft.note?.tags.joined(separator: ", ") ?? "")
    }

    private var tagValues: [String] {
        tags.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(title: "Note and Tags", symbol: "tag", tint: .indigo)
            if let path = draft.match?.relativePath ?? draft.note?.reference.relativePath {
                Text(path).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 100)
                .border(.secondary.opacity(0.3))
                .accessibilityLabel("Note")
            TextField("Tags, separated by commas", text: $tags)
                .textFieldStyle(.roundedBorder)
            if let problem { Text(problem).foregroundStyle(.secondary) }
            HStack {
                if let note = draft.note {
                    Button("Remove Note and Tags", role: .destructive) {
                        finish { try drives.removeCatalogNote(note.id) }
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    finish {
                        if let note = draft.note {
                            try drives.updateCatalogNote(note.id, text: text, tags: tagValues)
                        } else if let match = draft.match {
                            try drives.addCatalogNote(text, tags: tagValues, to: match)
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          && tagValues.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 450)
    }

    private func finish(_ action: () throws -> Void) {
        do {
            try action()
            dismiss()
        } catch { problem = error.localizedDescription }
    }
}

struct DriveCatalogNotesSheet: View {
    let drives: DrivesModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var response: Response?
    @State private var searchError: String?
    @State private var revealError: String?
    @State private var draft: CatalogNoteDraft?

    private struct Request: Equatable {
        let query: String
        let notes: [DriveCatalogNote]
        let catalogs: [DriveCatalogSummary]
    }

    private struct Response {
        let request: Request
        let items: [DriveCatalogNoteItem]
    }

    var body: some View {
        let request = Request(query: query, notes: drives.catalogNotes, catalogs: drives.catalogs)
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(title: "Catalog Notes & Tags", symbol: "tag", tint: .indigo)
            TextField("Search notes, tags, and saved paths", text: $query)
                .textFieldStyle(.roundedBorder)
            if let problem = searchError ?? revealError {
                Text(problem).foregroundStyle(.secondary)
            }
            if let response, response.request == request {
                if response.items.isEmpty {
                    Text(request.notes.isEmpty ? "Add notes and tags from any cataloged file." : "No matching notes or tags.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(response.items) { item in row(item) }
                        }
                    }
                }
            } else if searchError == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 560, height: 440)
        .sheet(item: $draft) { CatalogNoteEditor(drives: drives, draft: $0) }
        .task(id: request) {
            searchError = nil
            do {
                let items = try await drives.catalogNoteItems(matching: request.query)
                if !Task.isCancelled { response = Response(request: request, items: items) }
            } catch {
                if !Task.isCancelled { searchError = error.localizedDescription }
            }
        }
    }

    private func row(_ item: DriveCatalogNoteItem) -> some View {
        let online = drives.volumes.contains { $0.id == item.note.reference.driveID && drives.canCatalog($0) }
        return VStack(alignment: .leading, spacing: 5) {
            Text(item.match?.relativePath ?? item.note.reference.relativePath)
                .font(.headline).textSelection(.enabled)
            Text(item.driveName).font(.caption).foregroundStyle(.secondary)
            if item.match == nil {
                Text("File unavailable in the saved catalog.").font(.caption).foregroundStyle(.secondary)
            } else if !online {
                if let location = drives.storageLocation(for: item.note.reference.driveID) {
                    DriveStorageLocationLabel(note: location)
                } else {
                    Text("Reconnect drive").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !item.note.text.isEmpty { Text(item.note.text).textSelection(.enabled) }
            if !item.note.tags.isEmpty {
                Label(item.note.tags.joined(separator: ", "), systemImage: "tag")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Edit") { draft = .init(match: item.match, note: item.note) }
                    .accessibilityLabel("Edit note for \(item.note.reference.relativePath)")
                if online, item.match != nil {
                    Button("Show in Finder") {
                        Task { revealError = await drives.revealCatalogNote(item) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .groupRow()
    }
}
