import CoreTransferable
import AndromedaAppModel
import AndromedaCore
import AndromedaOrganize
import SwiftUI
import UniformTypeIdentifiers

struct ArchivesView: View {
    let model: AppModel
    var focusedArchive: UUID?
    @State private var search = ""
    @State private var fileSearch: (term: String, result: Result<ArchiveFileSearch, Error>)?
    @State private var lastRestoredFile: (archiveID: UUID, relativePath: String, destination: URL)?
    @State private var trashCandidate: ArchiveRecord?
    @State private var restoreCandidate: ArchiveRecord?
    @State private var showsVerificationTools = false
    @State private var choosingChecksumFile = false
    @State private var choosingChecksumRoot = false
    @State private var checksumPickerFailed = false
    @State private var checksumExportTask: Task<Void, Never>?
    @State private var checksumExport: ChecksumManifestExport?
    @State private var exportingChecksums = false
    @State private var checksumExportError: String?
    @State private var choosingCopy = false
    @State private var copyPicker: CopyPickerRequest?
    @State private var copyPickerFailed = false

    private var archives: ArchivesModel { model.archives }
    private var drives: [ExternalVolume] { model.drives.volumes.filter(ExternalArchive.supports) }
    private var searchTerm: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private struct CopyPickerRequest {
        let slot: ArchivesModel.ExistingCopySlot
        let selection: ArchivesModel.ExistingCopySelection
    }
    private struct SearchRequest: Equatable {
        let term: String
        let records: [ArchiveRecord]
    }

    private var filtered: [ArchiveRecord] {
        let term = searchTerm
        if term.isEmpty, let focusedArchive, let record = archives.records.first(where: { $0.id == focusedArchive }) {
            return [record] + archives.records.filter { $0.id != focusedArchive }
        }
        guard !term.isEmpty else { return archives.records }
        return archives.records.filter {
            $0.name.localizedStandardContains(term) || $0.originalPath.localizedStandardContains(term)
                || $0.driveName.localizedStandardContains(term)
                || model.drives.storageLocation(for: $0.driveID)?.localizedStandardContains(term) == true
        }
    }

    var body: some View {
        PageColumn(scrollsToTopOn: archives.preview?.previousVersionID == nil ? nil : archives.preview?.destinations.first?.id) {
            PageHeader(
                title: UICopy.archivesTitle, subtitle: UICopy.archivesSubtitle,
                symbol: "externaldrive.badge.checkmark")
            adaptiveActions {
                Button(archives.source == nil ? "Create Verified Archive…" : "Choose Another Source…") {
                    Task { await archives.chooseSource() }
                }
                .buttonStyle(.borderedProminent)
                .help("Choose a project on this Mac or a folder such as DCIM on a connected camera card.")
                .disabled(!archives.canStart)

                Button(showsVerificationTools ? "Hide Verification Tools" : "Verify Existing Files") {
                    showsVerificationTools.toggle()
                }
                .help("Compare two copies or check files against saved checksums.")
            }
            if let problem = archives.problem {
                Banner(text: problem, symbol: "exclamationmark.triangle.fill", tint: .orange)
            }
            if let notice = archives.notice {
                Banner(text: notice, symbol: "checkmark.circle.fill", tint: .green)
            }
            if let work = archives.work {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(work.rawValue)
                    if let drive = archives.progress?.currentEntry {
                        Text(drive).foregroundStyle(.secondary)
                    }
                    if let progress = archives.progress, progress.itemsChecked > 0 {
                        Text(ByteFormat.string(progress.bytesMeasured)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Cancel") { archives.cancel() }
                }
                .card()
            }
            if let source = archives.source { newArchive(source) }
            if !archives.offloadResults.isEmpty { offloadReport }
            if showsVerificationTools {
                existingCopiesCard
                checksumVerificationCard
            }
            savedArchives
        }
        .fileImporter(isPresented: $choosingChecksumFile, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url):
                let chooseFolder = choosingChecksumRoot
                Task { await archives.verifyChecksumFile(url, chooseFolder: chooseFolder) }
            case .failure: checksumPickerFailed = true
            }
        }
        .alert("Couldn’t Open Checksum File", isPresented: $checksumPickerFailed) {
            Button("OK", role: .cancel) {}
        }
        .fileExporter(isPresented: $exportingChecksums, item: checksumExport,
                      contentTypes: [ChecksumManifestExport.contentType], defaultFilename: checksumExport?.suggestedName) { result in
            checksumExport = nil
            if case .failure(let error) = result { checksumExportError = error.localizedDescription }
        } onCancellation: {
            checksumExport = nil
        }
        .alert("Couldn’t Save Folder Checksums", isPresented: Binding(
            get: { checksumExportError != nil }, set: { if !$0 { checksumExportError = nil } }
        ), presenting: checksumExportError) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error)
        }
        .onDisappear {
            checksumExportTask?.cancel()
            exportingChecksums = false
            checksumExport = nil
        }
        .task {
            await model.drives.refreshInBackground()
            await archives.reload()
        }
        .task(id: SearchRequest(term: searchTerm, records: archives.records)) {
            fileSearch = nil
            let term = searchTerm
            guard !term.isEmpty else { return }
            do {
                try await Task.sleep(for: .milliseconds(180))
                let result = try await archives.searchFiles(term)
                guard !Task.isCancelled else { return }
                fileSearch = (term, .success(result))
            } catch {
                if !Task.isCancelled { fileSearch = (term, .failure(error)) }
            }
        }
        .alert("Move the original to Trash?", isPresented: Binding(
            get: { trashCandidate != nil }, set: { if !$0 { trashCandidate = nil } }
        ), presenting: trashCandidate) { record in
            Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
            Button("Move Original to Trash", role: .destructive) { Task { await archives.trash(record) } }
        } message: { record in
            Text("Andromeda will check both copies again, then move \(record.name) on this Mac to Trash. The archive stays on \(record.driveName). Files in Trash continue to use local space.")
        }
        .alert("Restore a verified copy?", isPresented: Binding(
            get: { restoreCandidate != nil }, set: { if !$0 { restoreCandidate = nil } }
        ), presenting: restoreCandidate) { record in
            Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
            if record.sourceVolumeName == nil {
                Button("Restore to Original Folder") { Task { await archives.restore(record) } }
            }
            Button(record.sourceVolumeName == nil ? "Choose Another Folder…" : "Choose Local Folder…") {
                Task { await archives.restore(record, chooseFolder: true) }
            }
        } message: { record in
            Text("Andromeda will copy \(record.name) back to the Mac and verify the result. The external copy stays available.")
        }
    }

    @ViewBuilder private var savedArchives: some View {
        SectionHeading(title: "Saved archives", subtitle: "Search projects and their files, even while the drive is unplugged.")
        if let problem = archives.automaticCheckProblem {
            Banner(text: problem, symbol: "exclamationmark.triangle.fill", tint: .orange)
        }
        if archives.records.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("No saved archives yet").font(.headline)
                Text("Choose a project or camera folder and a writable APFS drive to make your first verified copy.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .card()
        } else {
            HStack {
                TextField("Search archives and files", text: $search).textFieldStyle(.roundedBorder)
                if !search.isEmpty {
                    Button("Clear Search", systemImage: "xmark.circle.fill") { search = "" }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                }
            }
            if searchTerm.isEmpty {
                LazyInsetList(items: filtered) { record in archiveRow(record) }
            } else {
                searchResults
            }
        }
        DisclosureGroup("Automatic integrity checks") {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Check connected archives automatically", isOn: Binding(
                    get: { archives.automaticChecks }, set: { archives.automaticChecks = $0 }))
                Text("While Andromeda is open, connected archives are checked 30 days after their last verification.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        }
    }

    private func adaptiveActions<Actions: View>(@ViewBuilder _ actions: () -> Actions) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8, content: actions)
            VStack(alignment: .leading, spacing: 8, content: actions)
        }
    }

    private var checksumVerificationCard: some View {
        let canChoose = archives.canCheckChecksums && checksumExportTask == nil && !exportingChecksums
        return VStack(alignment: .leading, spacing: 9) {
            SectionHeading(title: "Folder checksums")
            Text("Save a SHA-256 manifest or check the file data listed in one.")
                .font(.callout).foregroundStyle(.secondary)
            adaptiveActions {
                Button("Choose Checksum File…") { chooseChecksumFile(chooseFolder: false) }
                    .help("Check the files beside the checksum manifest.")
                Button("Verify Against Another Folder…") { chooseChecksumFile(chooseFolder: true) }
                    .help("Choose a checksum manifest, then choose the folder containing the files to check.")
                Button("Save Folder Checksums…", action: prepareChecksumExport)
            }
            .disabled(!canChoose)
            if let report = archives.checksumReport {
                let result = report.verification
                HStack {
                    Text(result.manifestName).font(.headline)
                    Spacer()
                    Button("Dismiss", action: archives.dismissChecksumVerification)
                }
                if let folder = report.chosenFolder {
                    Text("Checked in \(folder.path)")
                        .font(.callout).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(folder.path)
                }
                Text("\(result.verified.formatted()) matched · \(result.failed.formatted()) need review")
                if !result.issues.isEmpty {
                    DisclosureGroup("Files to review") {
                        ScrollablePathList(paths: result.issues.map { "\($0.kind.rawValue) · \($0.path)" })
                        if result.failed > result.issues.count {
                            Text("Showing the first \(result.issues.count) files that need review.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .card()
    }

    private func chooseChecksumFile(chooseFolder: Bool) {
        choosingChecksumRoot = chooseFolder
        choosingChecksumFile = true
    }

    private func prepareChecksumExport() {
        checksumExportTask = Task {
            defer { checksumExportTask = nil }
            guard let prepared = await archives.prepareFolderChecksums(), !Task.isCancelled else { return }
            checksumExport = ChecksumManifestExport(data: prepared.data, suggestedName: prepared.suggestedName)
            exportingChecksums = true
        }
    }

    private var existingCopiesCard: some View {
        let selection = archives.existingCopySelection
        return VStack(alignment: .leading, spacing: 9) {
            SectionHeading(title: "Verify existing copies")
            Picker("Compare", selection: Binding(
                get: { archives.existingCopySelection.kind }, set: { archives.selectExistingCopyKind($0) }
            )) {
                Text("Files").tag(ArchivesModel.ExistingCopyKind.files)
                Text("Folders").tag(ArchivesModel.ExistingCopyKind.folders)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220, alignment: .leading)
            .disabled(!archives.canStart)
            Text(selection.kind == .files
                 ? "Compare the data forks of two files using SHA-256. Tags, permissions, and resource forks may differ even if the data matches."
                 : "Compare relative paths and file data forks in two local folders. Finder tags, permissions, and resource forks can differ.")
                .font(.callout).foregroundStyle(.secondary)
            copyPickerRow(.first, selection: selection)
            copyPickerRow(.second, selection: selection)
            Button("Verify Copies") {
                Task { await archives.verifyExistingCopies(selection) }
            }
            .disabled(!archives.canStart || selection.first == nil || selection.second == nil)
            switch archives.existingCopyResult {
            case .files(let result):
                Divider()
                copyVerificationHeading(result.contents == .match ? "File data matches" : "File data differs",
                                        matches: result.contents == .match)
                copyVerificationDetails(result.first, result.second, kind: .files,
                                        location: result.location, checkedAt: result.checkedAt)
            case .folders(let result):
                Divider()
                let matches = result.differenceCount == 0
                copyVerificationHeading(matches ? "Folder paths and file data match" : "Folders differ", matches: matches)
                Text("\(result.matchingFiles.formatted()) matching files · \(result.differenceCount.formatted()) differing paths")
                    .font(.callout).foregroundStyle(.secondary)
                if !matches {
                    ScrollablePathList(paths: result.differences.map { "\(differenceText($0.kind)) · \($0.relativePath)" })
                    if result.differenceCount > result.differences.count {
                        Text("Showing \(result.differences.count.formatted()) of \(result.differenceCount.formatted()) differing paths.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                copyVerificationDetails(result.first, result.second, kind: .folders,
                                        location: result.location, checkedAt: result.checkedAt)
            case nil:
                EmptyView()
            }
        }
        .card()
        .fileImporter(isPresented: $choosingCopy, allowedContentTypes: [(copyPicker?.selection ?? selection).kind.contentType]) { result in
            guard let request = copyPicker else { return }
            copyPicker = nil
            guard request.selection == archives.existingCopySelection else { return }
            switch result {
            case .success(let url):
                archives.pickExistingCopy(url, for: request.slot, in: request.selection)
            case .failure:
                copyPickerFailed = true
            }
        }
        .alert("Couldn’t Open the Selected \(selection.kind.noun)", isPresented: $copyPickerFailed) {
            Button("OK", role: .cancel) {}
        }
    }

    private func copyPickerRow(_ slot: ArchivesModel.ExistingCopySlot, selection: ArchivesModel.ExistingCopySelection) -> some View {
        let first = slot == .first
        return adaptiveActions {
            Button("Choose \(first ? "First" : "Second") \(selection.kind.noun)…") {
                copyPicker = CopyPickerRequest(slot: slot, selection: selection)
                choosingCopy = true
            }
            .disabled(!archives.canStart)
            if let file = first ? selection.first : selection.second {
                Text(file.path).lineLimit(1).truncationMode(.middle).help(file.path)
            }
        }
    }

    private func copyVerificationHeading(_ title: String, matches: Bool) -> some View {
        HStack {
            Label(title, systemImage: matches ? "checkmark.circle" : "exclamationmark.triangle").font(.headline)
            Spacer()
            Button("Dismiss", action: archives.dismissExistingCopyVerification)
        }
    }

    @ViewBuilder private func copyVerificationDetails(_ first: URL, _ second: URL,
                                                     kind: ArchivesModel.ExistingCopyKind,
                                                     location: ExistingCopyVerification.Location, checkedAt: Date) -> some View {
        let noun = kind.noun.lowercased()
        ScrollablePathList(paths: ["First \(noun) · \(first.path)", "Second \(noun) · \(second.path)"])
        Text(locationText(location, noun: noun))
        Text("Checked \(checkedAt.formatted(date: .abbreviated, time: .shortened))")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func locationText(_ location: ExistingCopyVerification.Location, noun: String) -> String {
        switch location {
        case .sameFile: return "Both choices refer to the same file."
        case .sameFolder: return "Both choices refer to the same folder."
        case .sameVolume: return "Both \(noun)s are on the same volume."
        case .sharedDrive: return "These volumes share a physical drive."
        case .separateDrives: return "The \(noun)s are on separate physical drives."
        case .unknown: return "The physical drive relationship could not be verified."
        }
    }

    private func differenceText(_ kind: ExistingCopyVerification.FolderResult.Difference.Kind) -> String {
        switch kind {
        case .firstOnly: "Only in first folder"
        case .secondOnly: "Only in second folder"
        case .type: "A file in one folder and a folder in the other"
        case .data: "File data differs"
        }
    }

    @ViewBuilder private var searchResults: some View {
        let matchingArchives = filtered
        if let search = fileSearch, search.term == searchTerm {
            switch search.result {
            case .success(let result):
                if result.matches.isEmpty, matchingArchives.isEmpty {
                    Text(result.missingCatalogs ? "No matches in the saved archive information."
                         : "No matching archives or files.").foregroundStyle(.secondary).card()
                } else if !result.matches.isEmpty {
                    SectionHeading(title: "Matching files")
                    LazyInsetList(items: result.matches) { archiveFileRow($0) }
                }
                if result.hasMore {
                    Text("Showing the first 100 files. Refine your search to narrow the results.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if result.missingCatalogs {
                    Text("Some archives don’t have saved filenames. Reconnect their drives and run Check Integrity to add them.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            case .failure:
                Text("Andromeda couldn’t search archived files.").foregroundStyle(.secondary)
            }
        } else {
            ProgressView("Searching archived files…").controlSize(.small)
        }
        if !matchingArchives.isEmpty {
            SectionHeading(title: "Matching archives")
            LazyInsetList(items: matchingArchives) { archiveRow($0) }
        }
    }

    private func archiveFileRow(_ match: ArchiveFileMatch) -> some View {
        let connected = drives.contains { $0.id == match.archive.driveID }
        let context = "\(match.relativePath) in \(match.archive.name) on \(match.archive.driveName)"
        return VStack(alignment: .leading, spacing: 8) {
            Text(match.relativePath)
                .font(.headline).lineLimit(2).truncationMode(.middle).help(match.relativePath)
            Text("\(match.archive.name) · \(match.archive.driveName)")
                .font(.callout).foregroundStyle(.secondary)
            if connected {
                adaptiveActions {
                    Button("Show in Finder") { Task { await archives.reveal(match) } }
                        .accessibilityLabel("Show \(context) in Finder")
                    Button("Restore File…") {
                        Task {
                            if let destination = await archives.restoreFile(match) {
                                lastRestoredFile = (match.archive.id, match.relativePath, destination)
                            }
                        }
                    }
                    .accessibilityLabel("Restore \(context)")
                    .help("Choose a destination and verify the restored copy against the saved checksum.")
                    .disabled(!archives.canStart)
                }
            } else {
                Label("Connect \(match.archive.driveName) to restore this file.", systemImage: "externaldrive")
                    .font(.callout).foregroundStyle(.secondary)
                if let note = model.drives.storageLocation(for: match.archive.driveID) {
                    DriveStorageLocationLabel(note: note)
                }
            }
            if let restored = lastRestoredFile,
               restored.archiveID == match.archive.id, restored.relativePath == match.relativePath {
                adaptiveActions {
                    Label("Restored and verified", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                    Button("Show Restored File") { model.reveal(restored.destination) }
                        .buttonStyle(.link)
                        .accessibilityLabel("Show restored copy of \(context) in Finder")
                        .help(restored.destination.path)
                }
                .font(.callout)
            }
        }
        .groupRow()
    }

    private func newArchive(_ source: URL) -> some View {
        let connected = Set(drives.map(\.id))
        let missing = archives.driveIDs.filter { !connected.contains($0) }
        return VStack(alignment: .leading, spacing: 12) {
            Text(archives.preview?.previousVersionID == nil ? "New archive" : "New archive version").font(.headline)
            Text(source.path).textSelection(.enabled)
            if !missing.isEmpty {
                HStack {
                    Text("Some selected drives are disconnected.").foregroundStyle(.secondary)
                    Button("Deselect Disconnected Drives") { archives.driveIDs.removeAll { missing.contains($0) } }
                        .disabled(!archives.canStart)
                }
            }
            if drives.isEmpty {
                Text("Connect a writable APFS drive to make an archive.").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Destination drives").font(.subheadline.weight(.semibold))
                    ForEach(drives) { drive in
                        Toggle(isOn: Binding(
                            get: { archives.driveIDs.contains(drive.id) },
                            set: { selected in
                                if selected { archives.driveIDs.append(drive.id) }
                                else { archives.driveIDs.removeAll { $0 == drive.id } }
                            }
                        )) {
                            Text("\(drive.name) · \(ByteFormat.string(drive.available)) available")
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .disabled(!archives.canStart || archives.preview?.previousVersionID != nil)
                if let preview = archives.preview {
                    Divider()
                    if let media = preview.mediaSourceName {
                        Label("Source media: \(media)", systemImage: "sdcard")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(preview.destinations) { destination in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(destination.drive.name).font(.subheadline.weight(.semibold))
                            Text(destination.url.path).font(.callout).textSelection(.enabled)
                        }
                    }
                    let sizeLabel = preview.previousVersionID == nil ? "Allow at least" : "Full copy estimate"
                    Text("\(preview.fileCount.formatted()) \(preview.fileCount == 1 ? "file" : "files") · \(sizeLabel) \(ByteFormat.string(preview.requiredBytes)) per drive")
                        .foregroundStyle(.secondary)
                    if preview.previousVersionID != nil {
                        Text("Keeps the earlier version on this drive and shares storage for unchanged files when possible.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Button(preview.destinations.count == 1 ? "Copy and Verify" : "Copy and Verify on \(preview.destinations.count) Drives") {
                        Task { await archives.copy() }
                    }
                        .disabled(!archives.canStart)
                } else {
                    Button("Review Copy") { Task { await archives.prepare() } }
                        .disabled(!archives.canStart || archives.driveIDs.isEmpty || !missing.isEmpty)
                }
            }
        }
        .card()
    }

    private var offloadReport: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Copy Results").font(.headline)
            ForEach(archives.offloadResults) { result in
                LabeledContent(result.destination.drive.name) {
                    switch result.outcome {
                    case .verified: Label("Verified", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failed(let reason): Text(reason).foregroundStyle(.secondary)
                    case .needsRecovery: Text("Verify and recover the saved archive below.").foregroundStyle(.secondary)
                    case .sourceChanged: Text("Source changed. Review it again before copying.").foregroundStyle(.secondary)
                    case .cancelled: Text("Cancelled").foregroundStyle(.secondary)
                    }
                }
            }
            Text("The offload kept the original in place.").font(.callout).foregroundStyle(.secondary)
        }
        .card()
    }

    private func archiveRow(_ record: ArchiveRecord) -> some View {
        let online = drives.contains { $0.id == record.driveID }
        let url = archives.archivedURL(record, on: drives)
        let canShowChecksums = url != nil && record.hasPortableChecksums
        let canSetLocation = model.drives.canSetStorageLocation(for: record.driveID)
        let needsReview = record.integrityCheck?.outcome == .mismatch
        let canMakeVersion = record.sourceVolumeName == nil && record.additionalCopyOf == nil
        let destinations = ExternalArchive.additionalCopyDestinations(for: record, on: drives, records: archives.records)
        return VStack(alignment: .leading, spacing: 6) {
            ArchiveRecordSummary(record: record)
            if let check = record.integrityCheck, needsReview {
                if let differences = check.differences, !differences.isEmpty {
                    integrityDetails(differences, archiveName: record.name)
                } else {
                    Text("This check could only compare the archive as a whole.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if !online {
                Label("Connect \(record.driveName) to access this copy.", systemImage: "externaldrive")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if canShowChecksums || canSetLocation {
                HStack {
                    if let note = model.drives.storageLocation(for: record.driveID) {
                        DriveStorageLocationLabel(note: note)
                    }
                    Spacer()
                    if canShowChecksums {
                        Button("Show Checksums in Finder") { Task { await archives.revealChecksums(record) } }
                            .help("Find the portable SHA-256 manifest beside the archive.")
                            .disabled(!archives.canStart)
                    }
                    if canSetLocation {
                        DriveStorageLocationButton(drives: model.drives, id: record.driveID, name: record.driveName)
                    }
                }
                .controlSize(.small)
            }
            if record.state == .copying {
                Text(record.additionalCopyOf == nil
                    ? "Review the source and destination again to start a new verified copy."
                    : "Open the source archive to retry the additional copy.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            adaptiveActions {
                if let url {
                    Button("Show in Finder") { model.reveal(url) }
                    Button("Check Integrity") { Task { await archives.checkIntegrity(record) } }
                        .help("Compare the archived contents and metadata with the saved verification.")
                    if canMakeVersion {
                        Button("Review New Version…") {
                            Task { await archives.prepareNewVersion(of: record) }
                        }
                        .help("Review a new version from the original folder on this Mac.")
                    }
                    if !needsReview {
                        if record.state == .verified, record.additionalCopyOf == nil, record.sourceVolumeName == nil {
                            Button("Move Original to Trash…") { trashCandidate = record }
                        }
                        Button("Restore a Copy…") { restoreCandidate = record }
                        Menu("Copy to Another Drive…") {
                            ForEach(destinations) { drive in
                                Button("Copy and verify on \(drive.name) (\(drive.url.path))") {
                                    Task { await archives.copyToAnotherDrive(record, driveID: drive.id) }
                                }
                            }
                        }
                        .disabled(destinations.isEmpty)
                        .help(destinations.isEmpty
                            ? "Connect a writable APFS drive that doesn’t already contain this archive."
                            : "Create an additional verified copy on a separate physical disk.")
                    }
                } else if online, record.state == .sealed {
                    Button("Verify and Recover") { Task { await archives.recover(record) } }
                }
            }
            .disabled(!archives.canStart)
        }
        .groupRow()
    }

    private func integrityDetails(_ differences: [ArchiveRecord.IntegrityCheck.Difference], archiveName: String) -> some View {
        DisclosureGroup {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(differences.indices, id: \.self) { index in
                        let difference = differences[index]
                        let path = difference.relativePath.isEmpty ? archiveName : difference.relativePath
                        HStack(alignment: .firstTextBaseline) {
                            Text(path).textSelection(.enabled)
                            Spacer()
                            switch difference.kind {
                            case .changed: Text("Changed")
                            case .missing: Text("Missing")
                            case .added: Text("Added")
                            }
                        }
                        .font(.callout)
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 220)
        } label: {
            Text(differences.count == 1 ? "1 affected item" : "\(differences.count) affected items")
        }
    }
}

private extension ArchivesModel.ExistingCopyKind {
    var noun: String { self == .files ? "File" : "Folder" }
    var contentType: UTType { self == .files ? .data : .folder }
}

private struct ChecksumManifestExport: Transferable {
    static let contentType = UTType(filenameExtension: "sha256", conformingTo: .utf8PlainText) ?? .utf8PlainText
    let data: Data
    let suggestedName: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: contentType) { $0.data }
    }
}

struct ArchiveRecordSummary: View {
    let record: ArchiveRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.name).font(.headline)
            Text("\(record.driveName) · \(record.copiedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.callout).foregroundStyle(.secondary)
            Text(record.originalPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let media = record.sourceVolumeName {
                Text("Copied from \(media)").font(.caption).foregroundStyle(.secondary)
            }
            if let reused = record.reusedFileCount {
                Text("Reused \(reused.formatted()) unchanged \(reused == 1 ? "file" : "files")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(stateText).font(.callout)
            if let check = record.integrityCheck {
                let matched = check.outcome == .matched
                Label {
                    Text("\(matched ? "Integrity check passed" : "Integrity check found a mismatch") · \(check.date.formatted(date: .abbreviated, time: .shortened))")
                } icon: {
                    Image(systemName: matched ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(matched ? Color.green : Color.orange)
                }
                .font(.callout)
            }
            if let restored = record.restoredPath {
                Text("Restored to \(restored)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var stateText: String {
        let copy = record.integrityCheck?.outcome == .mismatch ? "Archived copy" : "Verified copy"
        if record.additionalCopyOf != nil {
            switch record.state {
            case .copying: return "Additional copy incomplete."
            case .sealed: return "Additional copy interrupted at the last step. Verify it to recover it."
            case .verified: return record.integrityCheck?.outcome == .mismatch ? "Additional archived copy." : "Additional verified copy."
            default: break
            }
        }
        return switch record.state {
        case .copying: "Copy incomplete. The original was left in place."
        case .sealed: "Copy interrupted at the last step. Verify the external copy to recover it."
        case .verified: record.sourceVolumeName == nil ? "\(copy). The original was kept on the Mac." : "\(copy) from media."
        case .releasing: "The Trash handoff was interrupted. Check the original location and Trash."
        case .inTrash: "\(copy). The local original was moved to Trash."
        case .restored: "A copy was restored to the Mac."
        }
    }
}
