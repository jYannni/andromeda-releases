import Darwin
import AndromedaCore
import AndromedaOrganize
import Foundation

/// File storage for a future single automation owner. Importing old preferences is explicit and never writes them.
struct FolderAutomationSettingsStore {
    enum Mode: String, Codable, Sendable {
        case whileAppIsOpen
        case afterQuit
    }

    struct Snapshot: Codable, Equatable, Sendable {
        fileprivate(set) var schemaVersion: Int
        fileprivate(set) var revision: UUID
        var rules: [FolderAutomationRule]
        var pausedSources: Set<AutomationDirectories.Folder>
        var isAutomationPaused: Bool
        var mode: Mode
        // Earlier settings granted background execution only to rules without tag conditions.
        var matchesFinderTagsAfterQuit: Bool?

        init(rules: [FolderAutomationRule] = [], pausedSources: Set<AutomationDirectories.Folder> = [],
             isAutomationPaused: Bool = false, mode: Mode = .whileAppIsOpen, matchesFinderTagsAfterQuit: Bool? = nil) {
            schemaVersion = 1
            revision = UUID()
            self.rules = rules
            self.pausedSources = pausedSources
            self.isAutomationPaused = isAutomationPaused
            self.mode = mode
            self.matchesFinderTagsAfterQuit = matchesFinderTagsAfterQuit
        }
    }

    enum Failure: Error, Equatable {
        case invalidSnapshot
        case unreadableLegacySettings(String)
        case conflict(expected: UUID?, actual: UUID?)
        case unsafeFile
        case system(String, Int32)
    }

    private static let fileName = "folder-automation-v1.json"
    private static let lockName = "folder-automation-v1.lock"
    let directory: URL

    init(directory: URL) { self.directory = directory }

    init(journalDirectory: URL) { self.init(directory: journalDirectory.deletingLastPathComponent()) }

    /// Read the same rules and pause choices the foreground app uses. No snapshot or preferences are changed.
    static func importLegacy(from defaults: UserDefaults) throws -> Snapshot {
        if let rules = defaults.object(forKey: FolderAutomationLegacySettings.defaultsKey), !(rules is Data) {
            throw Failure.unreadableLegacySettings("Saved automation rules couldn’t be read.")
        }
        if let sources = defaults.object(forKey: FolderAutomationLegacySettings.pausedSourcesKey), !(sources is Data) {
            throw Failure.unreadableLegacySettings("Saved automation pauses couldn’t be read.")
        }
        if let paused = defaults.object(forKey: FolderAutomationLegacySettings.pausedKey), !(paused is Bool) {
            throw Failure.unreadableLegacySettings("The saved automation pause couldn’t be read.")
        }
        let state = FolderAutomationLegacySettings.load(from: defaults)
        if let problem = state.problem { throw Failure.unreadableLegacySettings(problem) }
        return Snapshot(rules: state.rules, pausedSources: state.pausedSources, isAutomationPaused: state.isAutomationPaused)
    }

    func load() throws -> Snapshot? {
        guard let fd = try openDirectory() else { return nil }
        defer { close(fd) }
        return try load(in: fd)
    }

    /// A nil expected revision creates a snapshot only if none exists. A failed write after replacement
    /// can leave the new data in place; reload before retrying.
    @discardableResult
    func save(_ snapshot: Snapshot, replacing expectedRevision: UUID?) throws -> Snapshot {
        try Self.validate(snapshot)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard let directoryFD = try openDirectory() else {
            throw Failure.system("open settings directory", ENOENT)
        }
        defer { close(directoryFD) }
        // Leave the lock file in place so every writer of this directory locks the same inode.
        let lockFD = openat(directoryFD, Self.lockName, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lockFD >= 0 else { throw Failure.system("open settings lock", errno) }
        defer { close(lockFD) }
        try Self.requirePrivateRegularFile(lockFD)
        while flock(lockFD, LOCK_EX) != 0 {
            if errno != EINTR { throw Failure.system("lock settings", errno) }
        }
        let actual = try load(in: directoryFD)?.revision
        guard expectedRevision == actual else { throw Failure.conflict(expected: expectedRevision, actual: actual) }
        var updated = snapshot
        updated.revision = UUID()
        try write(updated, in: directoryFD)
        return updated
    }

    private func openDirectory() throws -> Int32? {
        let path = directory.standardizedFileURL.path
        let openPath = path.hasPrefix("/var/") || path.hasPrefix("/tmp/") ? "/private" + path : path
        let fd = open(openPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        if fd >= 0 { return fd }
        if errno == ENOENT { return nil }
        throw Failure.system("open settings directory", errno)
    }

    private func load(in directoryFD: Int32) throws -> Snapshot? {
        let fd = openat(directoryFD, Self.fileName, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw Failure.system("open settings snapshot", errno)
        }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        try Self.requirePrivateRegularFile(fd)
        guard let data = try file.readToEnd(), let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            throw Failure.invalidSnapshot
        }
        try Self.validate(snapshot)
        return snapshot
    }

    private func write(_ snapshot: Snapshot, in directoryFD: Int32) throws {
        let data = try JSONEncoder().encode(snapshot)
        let temporary = Self.fileName + "." + UUID().uuidString
        let fd = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure.system("create temporary settings snapshot", errno) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer {
            try? file.close()
            unlinkat(directoryFD, temporary, 0)
        }
        try file.write(contentsOf: data)
        guard fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0 else {
            throw Failure.system("sync settings snapshot", errno)
        }
        guard renameat(directoryFD, temporary, directoryFD, Self.fileName) == 0 else {
            throw Failure.system("publish settings snapshot", errno)
        }
        guard fsync(directoryFD) == 0 else { throw Failure.system("sync settings directory", errno) }
    }

    private static func requirePrivateRegularFile(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Failure.system("inspect settings file", errno) }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & 0o077 == 0 else { throw Failure.unsafeFile }
    }

    private static func validate(_ snapshot: Snapshot) throws {
        guard snapshot.schemaVersion == 1,
              Set(snapshot.rules.map(\.id)).count == snapshot.rules.count,
              snapshot.pausedSources.isSubset(of: Set(snapshot.rules.map(\.directories.source))),
              configurationProblem(snapshot.rules) == nil else { throw Failure.invalidSnapshot }
    }

    static func configurationProblem(_ rules: [FolderAutomationRule]) -> String? {
        let enabled = rules.filter(\.enabled)
        let byPath = Dictionary(grouping: enabled) { NamingRules.key($0.directories.source.path) }
        guard byPath.values.allSatisfy({ group in
            group.allSatisfy { $0.directories.source == group.first?.directories.source }
        }) else { return "Pause rules that refer to the old folder before watching its replacement." }
        let sources = Set(byPath.keys)
        for backup in enabled.flatMap(\.backupFolders) {
            let path = NamingRules.key(backup.path)
            if sources.contains(where: { $0 == path || $0.hasPrefix(path + "/") })
                || enabled.contains(where: { $0.includesSubfolders && path.hasPrefix(NamingRules.key($0.directories.source.path) + "/") }) {
                return "A backup destination can’t overlap another watched folder."
            }
        }
        guard !enabled.contains(where: { $0.directories.source != $0.directories.destination
            && sources.contains(NamingRules.key($0.directories.destination.path)) })
        else { return "An automation destination can’t also be a watched folder." }
        guard !enabled.contains(where: { rule in
            guard rule.directories.allowsDestinationSubfolders else { return false }
            let prefix = NamingRules.key(rule.directories.destination.path) + "/"
            return sources.contains { $0.hasPrefix(prefix) }
        }) else { return "A generated subfolder destination can’t contain another watched folder." }
        for root in enabled.filter(\.includesSubfolders).map({ NamingRules.key($0.directories.source.path) }) {
            let prefix = root + "/"
            if sources.contains(where: { $0.hasPrefix(prefix) }) {
                return "A watched folder that includes subfolders can’t contain another watched folder."
            }
            if enabled.contains(where: { rule in
                let target = NamingRules.key(rule.directories.destination.path)
                return target.hasPrefix(prefix) || (target == root && rule.directories.allowsDestinationSubfolders)
            }) {
                return "An automation destination can’t be inside a folder that watches its subfolders."
            }
        }
        return nil
    }
}

enum FolderAutomationLegacySettings {
    // Older builds reject the envelope instead of running a rule with its content condition missing.
    private struct ContentRuleStorage: Codable {
        let rules: [FolderAutomationRule]

        static func isRequired(for group: FolderAutomationRule.ConditionGroup) -> Bool {
            group.contentsContains != nil || group.groups.contains(where: isRequired)
        }
    }

    // Older builds must stop rather than move originals after making untagged backups.
    private struct TaggedBackupRuleStorage: Codable {
        let rulesWithBackupTags: [FolderAutomationRule]
    }

    // Earlier versions must leave multi-copy rules disabled rather than skip required backup folders.
    private struct BackupChainRuleStorage: Codable {
        let rulesWithBackupChains: [FolderAutomationRule]
    }

    // Older builds must not run a broader rule after dropping an unknown extension condition.
    private struct FileExtensionRuleStorage: Codable {
        let rulesWithFileExtensions: [FolderAutomationRule]

        static func isRequired(for group: FolderAutomationRule.ConditionGroup) -> Bool {
            group.fileExtension != nil || group.groups.contains(where: isRequired)
        }
    }

    static let defaultsKey = "diskplain.folderAutomation.rules.v1"
    static let pausedSourcesKey = "diskplain.folderAutomation.pausedSources.v1"
    static let pausedKey = "diskplain.folderAutomation.paused"

    /// Older app builds only read the UserDefaults rules, so leave them paused after snapshot ownership begins.
    static func fenceRollback(in defaults: UserDefaults) -> Bool {
        defaults.set(true, forKey: pausedKey)
        return defaults.synchronize() && defaults.bool(forKey: pausedKey)
    }

    struct State {
        let rules: [FolderAutomationRule]
        let pausedSources: Set<AutomationDirectories.Folder>
        let isAutomationPaused: Bool
        let problem: String?
    }

    static func load(from defaults: UserDefaults) -> State {
        let isAutomationPaused = defaults.bool(forKey: Self.pausedKey)
        var rules: [FolderAutomationRule] = []
        var pausedSources: Set<AutomationDirectories.Folder> = []
        var settingsProblem: String?
        if let data = defaults.data(forKey: Self.defaultsKey) {
            let decoder = JSONDecoder()
            let decoded: [FolderAutomationRule]? = (try? decoder.decode(FileExtensionRuleStorage.self, from: data))?.rulesWithFileExtensions
                ?? (try? decoder.decode(BackupChainRuleStorage.self, from: data))?.rulesWithBackupChains
                ?? (try? decoder.decode(TaggedBackupRuleStorage.self, from: data))?.rulesWithBackupTags
                ?? (try? decoder.decode(ContentRuleStorage.self, from: data))?.rules
                ?? (try? decoder.decode([FolderAutomationRule].self, from: data))
            if let saved = decoded,
               Set(saved.map(\.id)).count == saved.count,
               FolderAutomationSettingsStore.configurationProblem(saved) == nil {
                rules = saved
            } else {
                settingsProblem = "Saved automation rules couldn’t be read."
            }
        }
        if let data = defaults.data(forKey: Self.pausedSourcesKey) {
            if let saved = try? JSONDecoder().decode(Set<AutomationDirectories.Folder>.self, from: data) {
                pausedSources = saved.intersection(rules.map(\.directories.source))
            } else if settingsProblem == nil {
                settingsProblem = "Saved automation pauses couldn’t be read."
            }
        }
        return State(rules: rules, pausedSources: pausedSources, isAutomationPaused: isAutomationPaused, problem: settingsProblem)
    }

    static func encode(_ updated: [FolderAutomationRule]) -> Data? {
        let encoder = JSONEncoder()
        if updated.contains(where: { FileExtensionRuleStorage.isRequired(for: $0.conditionGroup) }) {
            return try? encoder.encode(FileExtensionRuleStorage(rulesWithFileExtensions: updated))
        } else if updated.contains(where: { $0.backupFolders.count > 1 }) {
            return try? encoder.encode(BackupChainRuleStorage(rulesWithBackupChains: updated))
        } else if updated.contains(where: { $0.backupFolder != nil && $0.changesCopyTags }) {
            return try? encoder.encode(TaggedBackupRuleStorage(rulesWithBackupTags: updated))
        } else if updated.contains(where: { ContentRuleStorage.isRequired(for: $0.conditionGroup) }) {
            return try? encoder.encode(ContentRuleStorage(rules: updated))
        } else {
            return try? encoder.encode(updated)
        }
    }
}
