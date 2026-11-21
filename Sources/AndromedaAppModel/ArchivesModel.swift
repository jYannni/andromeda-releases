import AndromedaCore
import AndromedaOrganize
import Foundation
import Observation

@MainActor @Observable
public final class ArchivesModel {
    public enum Work: String { case checking = "Checking source and destinations…", copying = "Copying and verifying…",
        releasing = "Rechecking both copies…", restoring = "Restoring and verifying…",
        recovering = "Verifying the archive…", verifying = "Checking archive integrity…",
        checkingChecksums = "Checking the checksum manifest…",
        creatingChecksums = "Creating folder checksums…",
        checkingExistingCopies = "Verifying existing copies…",
        checkingExistingFolders = "Verifying existing folders…",
        automaticVerification = "Automatically checking archive integrity…" }

    public enum ExistingCopyKind: Hashable, Sendable { case files, folders }
    public enum ExistingCopySlot { case first, second }

    public struct ExistingCopySelection: Equatable {
        public let kind: ExistingCopyKind
        public let first: URL?
        public let second: URL?
        private let revision = UUID()

        fileprivate init(kind: ExistingCopyKind, first: URL? = nil, second: URL? = nil) {
            self.kind = kind
            self.first = first
            self.second = second
        }
    }

    public enum ExistingCopyResult: Sendable {
        case files(ExistingCopyVerification)
        case folders(ExistingCopyVerification.FolderResult)
    }

    public struct ChecksumReport {
        public let verification: PortableChecksumVerification
        public let chosenFolder: URL?
    }

    public struct ChecksumExport {
        public let data: Data
        public let suggestedName: String
    }

    public private(set) var source: URL?
    public var driveIDs: [String] = [] {
        didSet { if oldValue != driveIDs { preview = nil } }
    }
    public var driveID: String? {
        get { driveIDs.first }
        set { driveIDs = newValue.map { [$0] } ?? [] }
    }
    public private(set) var preview: ArchivePreview?
    public private(set) var offloadResults: [ArchiveOffloadResult] = []
    public private(set) var records: [ArchiveRecord] = []
    public private(set) var work: Work?
    public private(set) var progress: ScanProgress?
    public private(set) var problem: String?
    public private(set) var notice: String?
    public private(set) var checksumReport: ChecksumReport?
    public private(set) var existingCopySelection = ExistingCopySelection(kind: .files)
    public private(set) var existingCopyResult: ExistingCopyResult?
    public private(set) var automaticCheckProblem: String?
    public var automaticChecks: Bool {
        didSet {
            guard automaticChecks != oldValue else { return }
            defaults.set(automaticChecks, forKey: Self.automaticChecksKey)
            if !automaticChecks {
                automaticCheckProblem = nil
                if work == .automaticVerification { control?.cancel() }
            }
            scheduleAutomaticChecks()
        }
    }

    private static let automaticChecksKey = "diskplain.automaticArchiveIntegrityChecks.v1"
    private static let recheckInterval: TimeInterval = 30 * 86_400
    private var choosingChecksumFolder = false
    @ObservationIgnored private let service: ExternalArchive
    @ObservationIgnored private let deps: AppDependencies
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var control: ScanControl?
    @ObservationIgnored private var automaticChecksStarted = false
    @ObservationIgnored private var automaticScheduler: Task<Void, Never>?
    @ObservationIgnored private var automaticPassInProgress = false
    @ObservationIgnored weak var app: AppModel?

    init(deps: AppDependencies, defaults: UserDefaults) {
        self.deps = deps
        self.defaults = defaults
        automaticChecks = defaults.bool(forKey: Self.automaticChecksKey)
        service = ExternalArchive(
            env: deps.env, recordsDirectory: deps.journalDirectory.deletingLastPathComponent()
                .appendingPathComponent("archives", isDirectory: true),
            trasher: deps.trasher, volumes: deps.volumes)
    }

    public var canStart: Bool {
        guard work == nil else { return false }
        guard let app else { return true }
        return !app.organize.isApplying && !app.organize.isUndoing && !app.removal.isExecuting
    }

    public func offersArchive(_ url: URL) -> Bool { ExternalArchive.couldArchive(url, in: deps.env) }

    public func pick(_ url: URL) {
        guard canStart else { return }
        source = url
        preview = nil
        offloadResults = []
        notice = nil
        problem = nil
    }

    public func chooseSource() async {
        guard canStart, let folder = await deps.workspace.chooseFolder() else { return }
        pick(folder)
    }

    public func cancel() { control?.cancel() }

    func startAutomaticChecks() {
        guard !automaticChecksStarted else { return }
        automaticChecksStarted = true
        scheduleAutomaticChecks()
    }

    private func scheduleAutomaticChecks() {
        automaticScheduler?.cancel()
        automaticScheduler = nil
        guard automaticChecksStarted, automaticChecks else { return }
        automaticScheduler = Task { [weak self] in
            while !Task.isCancelled, let drives = self?.app?.drives.volumes {
                await self?.checkIfDue(on: drives)
                try? await Task.sleep(for: .seconds(900))
            }
        }
    }

    func checkIfDue(
        on drives: [ExternalVolume], now: Date = Date(), canRun: Bool = !ProcessInfo.processInfo.isLowPowerModeEnabled
    ) async {
        guard automaticChecks, canRun, canStart, app?.canScan != false, !automaticPassInProgress else { return }
        let driveIDs = Set(drives.filter(ExternalArchive.supports).map(\.id))
        guard !driveIDs.isEmpty else { return }
        automaticPassInProgress = true
        defer { automaticPassInProgress = false }
        let cutoff = now.addingTimeInterval(-Self.recheckInterval)
        let service = service
        let due: [ArchiveRecord]
        do {
            due = try await BackgroundWork.run("andromeda.archives.due", qos: .utility) {
                try service.dueIntegrityChecks(on: driveIDs, through: cutoff)
            }
        } catch {
            if automaticChecks, !Task.isCancelled {
                automaticCheckProblem = "Andromeda couldn’t read archive records for automatic checks."
            }
            return
        }
        guard automaticChecks, !Task.isCancelled, canStart, app?.canScan != false else { return }
        automaticCheckProblem = nil
        guard !due.isEmpty else { return }
        let failure = await run(.automaticVerification, qos: .utility) { service, control in
            var count = 0
            var first: String?
            for record in due {
                guard !control.isCancelled else { break }
                do {
                    try service.checkIntegrityIfDue(record.id, through: cutoff, control: control)
                } catch {
                    guard !control.isCancelled else { break }
                    count += 1
                    if first == nil { first = "\(record.name) couldn’t be checked. \(error.localizedDescription)" }
                }
            }
            if count > 1, let first { return "\(count) archives couldn’t be checked. \(first)" }
            return first ?? ""
        }
        if automaticChecks, !Task.isCancelled, let failure, !failure.isEmpty { automaticCheckProblem = failure }
        await reload()
    }

    @discardableResult
    public func reload() async -> Bool {
        let service = service
        do {
            records = try await BackgroundWork.run("andromeda.archives.load") { try service.records() }
            return true
        } catch {
            problem = "Andromeda couldn’t read the archive records. \(error.localizedDescription)"
            return false
        }
    }

    public func prepare() async {
        let driveIDs = driveIDs
        guard let source, !driveIDs.isEmpty, canStart else { return }
        preview = nil
        offloadResults = []
        let result = await run(.checking) { service, control in
            try service.preview(source: source, driveIDs: driveIDs, control: control)
        }
        if let result, self.source == source, self.driveIDs == driveIDs { preview = result }
    }

    public func prepareNewVersion(of record: ArchiveRecord) async {
        guard canStart else { return }
        preview = nil
        offloadResults = []
        guard let plan = await run(.checking, operation: { service, control in
            try service.previewNewVersion(of: record.id, control: control)
        }) else { return }
        source = plan.source
        driveIDs = plan.destinations.map(\.drive.id)
        preview = plan
    }

    public func copy() async {
        guard let preview, canStart else { return }
        self.preview = nil
        if preview.destinations.count == 1 {
            let result = await run(.copying) { service, control in try service.copy(preview, control: control) }
            if let result {
                if let reused = result.reusedFileCount {
                    notice = "New version verified on \(result.driveName). Reused \(reused.formatted()) unchanged \(reused == 1 ? "file" : "files")."
                } else {
                    notice = result.sourceVolumeName.map { "Media from \($0) verified on \(result.driveName)." }
                        ?? "Verified on \(result.driveName). The original is still on this Mac."
                }
                source = nil
            }
        } else if let results = await run(.copying, operation: { service, control in
            try service.offload(preview, control: control)
        }) {
            offloadResults = results
            if results.contains(where: { $0.verifiedRecord != nil }) { source = nil }
        }
        await reload()
    }

    public func copyToAnotherDrive(_ record: ArchiveRecord, driveID: String) async {
        let result = await run(.copying) { service, control in
            try service.copyToAnotherDrive(record.id, driveID: driveID, control: control)
        }
        if let result { notice = "Additional copy verified on \(result.driveName)." }
        await reload()
    }

    public func trash(_ record: ArchiveRecord) async {
        let result = await run(.releasing) { service, control in
            try service.trashOriginal(record.id, control: control)
        }
        if result != nil {
            notice = "The original is in Trash. Its space is available after it leaves Trash, subject to shared storage and snapshots."
        }
        await reload()
    }

    public func restore(_ record: ArchiveRecord, chooseFolder: Bool = false) async {
        guard canStart else { return }
        let folder = chooseFolder ? await deps.workspace.chooseFolder() : nil
        if chooseFolder, folder == nil { return }
        let result = await run(.restoring) { service, control in
            try service.restore(record.id, into: folder, control: control)
        }
        if let path = result?.restoredPath { notice = "Verified and restored to \(path)." }
        await reload()
    }

    @discardableResult
    public func restoreFile(_ match: ArchiveFileMatch) async -> URL? {
        guard canStart, let folder = await deps.workspace.chooseFolder() else { return nil }
        let result = await run(.restoring) { service, control in
            try service.restoreFile(match, into: folder, control: control)
        }
        if let result { notice = "Verified and restored to \(result.path)." }
        return result
    }

    public func recover(_ record: ArchiveRecord) async {
        let result = await run(.recovering) { service, control in
            try service.recover(record.id, control: control)
        }
        if result != nil { notice = "The archive was found and verified." }
        await reload()
    }

    public func checkIntegrity(_ record: ArchiveRecord) async {
        let result = await run(.verifying) { service, control in
            try service.checkIntegrity(record.id, control: control)
        }
        switch result?.integrityCheck?.outcome {
        case .matched: notice = "\(record.name) matches its saved verification."
        case .mismatch: problem = "\(record.name) no longer matches its saved verification."
        case nil: return
        }
        await reload()
    }

    public func archivedURL(_ record: ArchiveRecord, on drives: [ExternalVolume]) -> URL? {
        guard let drive = drives.first(where: { $0.id == record.driveID }) else { return nil }
        return service.archiveURL(record, on: drive)
    }

    public func revealChecksums(_ record: ArchiveRecord) async {
        let url = await run(.checkingChecksums) { service, control in
            try service.archivedChecksumsURL(record.id, control: control)
        }
        if let url { deps.workspace.reveal(url) }
    }

    public var canCheckChecksums: Bool { canStart && !choosingChecksumFolder }

    public func verifyChecksumFile(_ url: URL, chooseFolder: Bool = false) async {
        guard canCheckChecksums, !Task.isCancelled else { return }
        checksumReport = nil
        let folder: URL?
        if chooseFolder {
            guard let selection = await chooseChecksumFolder(), canStart, !Task.isCancelled else { return }
            folder = selection
        } else {
            folder = nil
        }
        let deps = deps
        let result = await run(.checkingChecksums, discardCancelledResult: true) { _, control in
            let accessingManifest = url.startAccessingSecurityScopedResource()
            let accessingFolder = folder?.startAccessingSecurityScopedResource() == true
            defer {
                if accessingManifest { url.stopAccessingSecurityScopedResource() }
                if accessingFolder { folder?.stopAccessingSecurityScopedResource() }
            }
            return try PortableChecksumVerification.verify(url, relativeTo: folder, env: deps.env,
                                                           canReadProtectedPaths: deps.fda() == .granted, control: control)
        }
        if let result, !Task.isCancelled {
            checksumReport = ChecksumReport(verification: result, chosenFolder: folder)
        }
    }

    public func dismissChecksumVerification() { checksumReport = nil }

    public func prepareFolderChecksums() async -> ChecksumExport? {
        guard canCheckChecksums, !Task.isCancelled,
              let folder = await chooseChecksumFolder(), canStart, !Task.isCancelled else { return nil }
        let deps = deps
        let snapshot = await run(.creatingChecksums, discardCancelledResult: true) { _, control in
            let accessing = folder.startAccessingSecurityScopedResource()
            defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
            return try PortableChecksumSnapshot.create(folder, env: deps.env,
                                                       canReadProtectedPaths: deps.fda() == .granted, control: control)
        }
        guard let snapshot, !Task.isCancelled else { return nil }
        return ChecksumExport(data: snapshot.data, suggestedName: "\(folder.lastPathComponent) Checksums.sha256")
    }

    private func chooseChecksumFolder() async -> URL? {
        choosingChecksumFolder = true
        defer { choosingChecksumFolder = false }
        return await deps.workspace.chooseFolder()
    }

    public func selectExistingCopyKind(_ kind: ExistingCopyKind) {
        guard canStart, kind != existingCopySelection.kind else { return }
        dismissExistingCopyVerification()
        existingCopySelection = ExistingCopySelection(kind: kind)
    }

    public func pickExistingCopy(_ url: URL, for slot: ExistingCopySlot, in selection: ExistingCopySelection) {
        guard canStart, selection == existingCopySelection else { return }
        // Selecting the same path again can renew access granted by the file importer.
        let first = slot == .first ? url : selection.first
        let second = slot == .second ? url : selection.second
        dismissExistingCopyVerification()
        existingCopySelection = ExistingCopySelection(kind: selection.kind, first: first, second: second)
    }

    public func verifyExistingCopies(_ selection: ExistingCopySelection) async {
        guard canStart, selection == existingCopySelection,
              let first = selection.first, let second = selection.second else { return }
        dismissExistingCopyVerification()
        let kind = selection.kind
        let result: ExistingCopyResult? = await run(kind == .files ? .checkingExistingCopies : .checkingExistingFolders) { _, control in
            let accessFirst = first.startAccessingSecurityScopedResource()
            let accessSecond = second.startAccessingSecurityScopedResource()
            defer {
                if accessFirst { first.stopAccessingSecurityScopedResource() }
                if accessSecond { second.stopAccessingSecurityScopedResource() }
            }
            switch kind {
            case .files: return .files(try ExistingCopyVerification.verify(first, second, control: control))
            case .folders: return .folders(try ExistingCopyVerification.verifyFolders(first, second, control: control))
            }
        }
        if selection == existingCopySelection { existingCopyResult = result }
    }

    public func dismissExistingCopyVerification() {
        existingCopyResult = nil
    }

    public func searchFiles(_ term: String) async throws -> ArchiveFileSearch {
        let control = ScanControl { _ in }
        let service = service
        return try await withTaskCancellationHandler {
            try await BackgroundWork.run("andromeda.archives.file-search") {
                try service.searchFiles(term, control: control)
            }
        } onCancel: {
            control.cancel()
        }
    }

    public func reveal(_ match: ArchiveFileMatch) async {
        let service = service
        do {
            let url = try await BackgroundWork.run("andromeda.archives.locate-file") {
                try service.archivedFileURL(match)
            }
            deps.workspace.reveal(url)
        } catch {
            problem = error.localizedDescription
        }
    }

    private func run<T: Sendable>(
        _ work: Work, qos: QualityOfService = .userInitiated,
        discardCancelledResult: Bool = false,
        operation: @escaping @Sendable (ExternalArchive, ScanControl) throws -> T
    ) async -> T? {
        guard canStart else { return nil }
        self.work = work
        if work != .automaticVerification {
            problem = nil
            notice = nil
        }
        progress = nil
        let token = UUID()
        activeToken = token
        let control = ScanControl { [weak self] progress in
            Task { @MainActor in
                guard let self, self.activeToken == token else { return }
                self.progress = progress
            }
        }
        self.control = control
        defer {
            self.work = nil
            self.control = nil
            activeToken = nil
            progress = nil
        }
        let service = service
        do {
            let result = try await withTaskCancellationHandler {
                try await BackgroundWork.run("andromeda.archive." + work.rawValue, qos: qos) {
                    try operation(service, control)
                }
            } onCancel: {
                control.cancel()
            }
            return discardCancelledResult && control.isCancelled ? nil : result
        } catch {
            if work != .automaticVerification && (!control.isCancelled || (!discardCancelledResult && work != .checkingExistingCopies)) {
                problem = error.localizedDescription
            }
            return nil
        }
    }

    @ObservationIgnored private var activeToken: UUID?
}
