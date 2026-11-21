import AndromedaAppModel
import SwiftUI

struct DriveStorageLocationLabel: View {
    let note: String

    var body: some View {
        Label {
            Text("Stored at \(note)").textSelection(.enabled)
        } icon: {
            Image(systemName: "mappin")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

struct DriveStorageLocationReminder: View {
    let drives: DrivesModel
    let drive: DrivesModel.OfflineDrive

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "mappin.circle.fill").foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text("Where are you storing \(drive.name)?").fontWeight(.medium)
                if let note = drives.storageLocation(for: drive.id) {
                    DriveStorageLocationLabel(note: note)
                }
            }
            Spacer(minLength: 12)
            DriveStorageLocationButton(drives: drives, id: drive.id, name: drive.name)
            Button("Skip") { drives.dismissLocationReminder(for: drive.id) }
            Menu {
                Button("Stop Reminding for This Drive") { drives.setLocationRemindersEnabled(false, for: drive.id) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Location reminder options for \(drive.name)")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct DriveStorageLocationButton: View {
    let drives: DrivesModel
    let id: String
    let name: String
    @State private var editing = false
    @State private var draft = ""

    private var location: String? { drives.storageLocation(for: id) }
    private var title: String { location == nil ? "Set Storage Location…" : "Edit Storage Location…" }

    var body: some View {
        if drives.canSetStorageLocation(for: id) {
            Button(title) {
                draft = location ?? ""
                editing = true
            }
            .accessibilityLabel("\(title) for \(name)")
            .popover(isPresented: $editing) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Storage Location").font(.headline)
                    Text(name).foregroundStyle(.secondary)
                    TextField("Where is this drive stored?", text: $draft)
                        .accessibilityLabel("Storage location")
                    HStack {
                        if location != nil {
                            Button("Clear Location") { save("") }
                        }
                        Spacer()
                        Button("Cancel") { editing = false }.keyboardShortcut(.cancelAction)
                        Button("Save") { save(draft) }
                            .keyboardShortcut(.defaultAction)
                            .disabled(!DrivesModel.isValidStorageLocation(draft))
                    }
                }
                .padding(16)
                .frame(width: 375)
            }
        }
    }

    private func save(_ text: String) {
        if drives.setStorageLocation(text, for: id, driveName: name) { editing = false }
    }
}
