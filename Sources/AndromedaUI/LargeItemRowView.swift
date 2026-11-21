import AppKit
import UniformTypeIdentifiers
import AndromedaAppModel
import SwiftUI

struct LargeItemRowView: View {
    let model: AppModel
    let ui: UIState
    let row: LargeItemRow
    /// Application rows offer only Show in Finder.
    var showsOrganize = true
    /// A drive row plans the item's folder. A Mac row opens the cloud suggestions.
    var organizesOnDrive = false

    private var organizeTitle: String {
        organizesOnDrive ? model.englishSpelling.wording(UICopy.organizeThisFolder) : UICopy.reviewMoveToCloud
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(nsImage: FileIcon.image(for: row.id, revealable: row.revealable))
                .resizable().frame(width: 28, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(.body.weight(.medium))
                Text(row.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            if row.revealable {
                HStack(spacing: 6) {
                    Button(UICopy.showInFinder) { model.reveal(row.id) }
                        .accessibilityLabel("Show \(row.name) in Finder")
                    if showsOrganize {
                        Button(organizeTitle) {
                            if organizesOnDrive { ui.organizeOnDrive(row.id, model: model) } else { ui.organizeThese(row.id, model: model) }
                        }
                        .accessibilityLabel("\(organizeTitle) for \(row.name)")
                    }
                }
                .controlSize(.small)
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text(row.sizeText).font(.body.weight(.semibold)).monospacedDigit()
                if let note = row.sharedNote { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
            .frame(minWidth: 72, alignment: .trailing)
        }
        .groupRow()
    }
}

/// A file's Finder icon without reading the file: apps by their bundle, everything else by its type.
/// Reading arbitrary paths here could set off privacy prompts for folders the scan never asked about.
enum FileIcon {
    static func image(for url: URL, revealable: Bool) -> NSImage {
        guard revealable else { return NSWorkspace.shared.icon(for: .applicationBundle) }
        if url.pathExtension == "app", url.path.hasPrefix("/Applications/") {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        let type = url.pathExtension.isEmpty ? UTType.folder : (UTType(filenameExtension: url.pathExtension) ?? .data)
        return NSWorkspace.shared.icon(for: type)
    }
}
