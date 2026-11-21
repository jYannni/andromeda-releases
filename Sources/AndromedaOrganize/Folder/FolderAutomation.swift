import Darwin
import AndromedaCore
import Foundation

public struct FolderAutomationRule: Codable, Equatable, Identifiable, Sendable {
    public enum MatchMode: String, Codable, Sendable { case all, any, none }
    public enum AgeBasis: String, CaseIterable, Codable, Sendable { case modified, created, added, opened }
    public enum FolderStructure: String, CaseIterable, Codable, Sendable { case flat, watchedFolder, immediateParent }
    public enum CollisionPolicy: String, Codable, Sendable { case leaveInPlace, numberIncoming }

    public struct ConditionGroup: Codable, Equatable, Sendable {
        public let matchMode: MatchMode
        public let pattern: String
        public let fileExtension: String?
        public let minimumBytes: Int64?
        public let maximumBytes: Int64?
        public let minimumAgeDays: Int?
        public let maximumAgeDays: Int?
        public let ageBasis: AgeBasis
        public let fileKind: Kind?
        public let finderTags: [String]
        public let contentsContains: String?
        private let savedRecognizesText: Bool?
        public var recognizesText: Bool { savedRecognizesText == true }
        public let groups: [ConditionGroup]

        public init(matchMode: MatchMode = .all, pattern: String = "", fileExtension: String? = nil,
                    minimumBytes: Int64? = nil, maximumBytes: Int64? = nil,
                    minimumAgeDays: Int? = nil, maximumAgeDays: Int? = nil, ageBasis: AgeBasis = .modified,
                    fileKind: Kind? = nil, finderTags: [String] = [], contentsContains: String? = nil,
                    recognizesText: Bool = false,
                    groups: [ConditionGroup] = []) {
            self.matchMode = matchMode
            self.pattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            self.fileExtension = fileExtension.map { FolderAutomationRule.normalizedFileExtension($0) ?? $0 }
            self.minimumBytes = minimumBytes
            self.maximumBytes = maximumBytes
            self.minimumAgeDays = minimumAgeDays
            self.maximumAgeDays = maximumAgeDays
            self.ageBasis = ageBasis
            self.fileKind = fileKind
            self.finderTags = finderTags.allSatisfy { FolderAutomationRule.isValidFinderTag($0) }
                ? FolderAutomationRule.normalizedTagNames(finderTags) : finderTags
            self.contentsContains = contentsContains?.trimmingCharacters(in: .whitespacesAndNewlines)
            savedRecognizesText = recognizesText ? true : nil
            self.groups = groups
        }

        public var hasConditions: Bool {
            !pattern.isEmpty || fileExtension != nil || minimumBytes != nil || maximumBytes != nil
                || minimumAgeDays != nil || maximumAgeDays != nil || fileKind != nil
                || !finderTags.isEmpty || contentsContains != nil || !groups.isEmpty
        }

        fileprivate var isValid: Bool {
            !pattern.contains("/") && FolderAutomationRule.isValidFileExtension(fileExtension)
                && (minimumBytes ?? 0) >= 0 && (minimumBytes ?? 0) <= (maximumBytes ?? .max)
                && (0...36_500).contains(minimumAgeDays ?? 0) && (0...36_500).contains(maximumAgeDays ?? 0)
                && (minimumAgeDays ?? 0) <= (maximumAgeDays ?? .max)
                && finderTags.allSatisfy { FolderAutomationRule.isValidFinderTag($0) }
                && (contentsContains.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? true)
                && (!recognizesText || contentsContains != nil)
                && groups.allSatisfy { $0.hasConditions && $0.isValid }
        }
    }

    public private(set) var id: UUID
    public let directories: AutomationDirectories
    public let backupFolder: AutomationDirectories.Folder?
    private let additionalBackupFolders: [AutomationDirectories.Folder]?
    public var backupFolders: [AutomationDirectories.Folder] {
        (backupFolder.map { [$0] } ?? []) + (additionalBackupFolders ?? [])
    }
    public let pattern: String
    public let fileExtension: String?
    public let minimumBytes: Int64?
    public let maximumBytes: Int64?
    public let minimumAgeDays: Int?
    public let maximumAgeDays: Int?
    private let savedAgeBasis: AgeBasis?
    public var ageBasis: AgeBasis { savedAgeBasis ?? .modified }
    public let fileKind: Kind?
    public let contentsContains: String?
    private let savedRecognizesText: Bool?
    public var recognizesText: Bool { savedRecognizesText == true }
    public let finderTag: String?
    public let excludedFinderTag: String?
    private let additionalFinderTags: [String]?
    private let additionalExcludedFinderTags: [String]?
    public var finderTags: [String] { (finderTag.map { [$0] } ?? []) + (additionalFinderTags ?? []) }
    public var excludedFinderTags: [String] { (excludedFinderTag.map { [$0] } ?? []) + (additionalExcludedFinderTags ?? []) }
    public let renamePrefix: String?
    public let renameTemplate: AutomationFilenameTemplate?
    public let subfolderTemplate: AutomationSubfolderTemplate?
    private let savedMatchMode: MatchMode?
    public var matchMode: MatchMode { savedMatchMode ?? .all }
    private let savedConditionGroups: [ConditionGroup]?
    public var conditionGroups: [ConditionGroup] { savedConditionGroups ?? [] }
    public var conditionGroup: ConditionGroup {
        .init(matchMode: matchMode, pattern: pattern, fileExtension: fileExtension,
              minimumBytes: minimumBytes, maximumBytes: maximumBytes,
              minimumAgeDays: minimumAgeDays, maximumAgeDays: maximumAgeDays, ageBasis: ageBasis,
              fileKind: fileKind, finderTags: finderTags, contentsContains: contentsContains,
              recognizesText: recognizesText, groups: conditionGroups)
    }
    private let savedIgnoresMatches: Bool?
    private let savedCopiesMatches: Bool?
    private let savedCopiesOnArrival: Bool?
    public var copiesOnArrival: Bool { copiesMatches && savedCopiesOnArrival == true }
    private let savedNotifiesOnCompletion: Bool?
    public var notifiesOnCompletion: Bool { !ignoresMatches && savedNotifiesOnCompletion == true }
    private let savedCopyFinderTags: [String]?
    public var copyFinderTags: [String] { savedCopyFinderTags ?? [] }
    private let savedCopyTagTemplates: [AutomationFinderTagTemplate]?
    public var copyTagTemplates: [AutomationFinderTagTemplate] { savedCopyTagTemplates ?? [] }
    private let savedRemovedCopyTags: [String]?
    public var removedCopyTags: [String] { savedRemovedCopyTags ?? [] }
    public var changesCopyTags: Bool { !copyFinderTags.isEmpty || !copyTagTemplates.isEmpty || !removedCopyTags.isEmpty }
    private let savedSkipsIdenticalCopies: Bool?
    public var skipsIdenticalCopies: Bool { copiesMatches && savedSkipsIdenticalCopies == true }
    private let savedCollisionPolicy: CollisionPolicy?
    private let savedNumbersBackupConflicts: Bool?
    private let savedIncludesSubfolders: Bool?
    public var includesSubfolders: Bool { savedIncludesSubfolders == true }
    private let savedPreservesSubfolderStructure: Bool?
    private let savedFolderStructure: FolderStructure?
    public var folderStructure: FolderStructure {
        savedFolderStructure ?? (savedPreservesSubfolderStructure == true ? .watchedFolder : .flat)
    }
    public var preservesSubfolderStructure: Bool { folderStructure != .flat }
    public let maximumSubfolderDepth: Int?
    public let includedSubfolderPattern: String?
    public let excludedSubfolderPattern: String?
    /// Zero covers the watched folder itself. Nil allows every depth.
    public var watchedDepthLimit: Int? {
        includesSubfolders ? maximumSubfolderDepth.map { max(0, $0) } : 0
    }
    public var collisionPolicy: CollisionPolicy { savedCollisionPolicy ?? .leaveInPlace }
    public var numbersBackupConflicts: Bool { backupFolder != nil && savedNumbersBackupConflicts == true }
    public var ignoresMatches: Bool { savedIgnoresMatches ?? false }
    public var copiesMatches: Bool { savedCopiesMatches ?? false }
    public var renamesInPlace: Bool { !ignoresMatches && directories.source == directories.destination && subfolderTemplate == nil }
    public var enabled: Bool

    public func disabledCopy() -> Self {
        var copy = self
        copy.id = UUID()
        copy.enabled = false
        return copy
    }

    /// A nil destination uses the watched folder as the base for a rename or subfolder sort.
    public init?(
        id: UUID = UUID(), source: URL, destination: URL?, backup: URL? = nil, additionalBackups: [URL] = [], pattern: String,
        fileExtension: String? = nil,
        minimumBytes: Int64? = nil, maximumBytes: Int64? = nil,
        minimumAgeDays: Int? = nil, maximumAgeDays: Int? = nil, ageBasis: AgeBasis = .modified,
        fileKind: Kind? = nil, finderTag: String? = nil,
        excludedFinderTag: String? = nil, finderTags: [String] = [], excludedFinderTags: [String] = [],
        matchMode: MatchMode = .all, contentsContains: String? = nil, recognizesText: Bool = false,
        conditionGroups: [ConditionGroup] = [],
        renamePrefix: String? = nil, renameTemplate: AutomationFilenameTemplate? = nil,
        subfolderTemplate: AutomationSubfolderTemplate? = nil, ignoresMatches: Bool = false, copiesMatches: Bool = false,
        copyFinderTags: [String] = [], copyTagTemplates: [AutomationFinderTagTemplate] = [], removedCopyTags: [String] = [],
        skipsIdenticalCopies: Bool = false, copiesOnArrival: Bool = false,
        collisionPolicy: CollisionPolicy = .leaveInPlace, numbersBackupConflicts: Bool = false,
        includesSubfolders: Bool = false, maximumSubfolderDepth: Int? = nil,
        preservesSubfolderStructure: Bool = false, folderStructure: FolderStructure? = nil,
        includedSubfolderPattern: String? = nil, excludedSubfolderPattern: String? = nil,
        notifiesOnCompletion: Bool = false, enabled: Bool = true, env: ScanEnvironment
    ) {
        let structure = folderStructure ?? (preservesSubfolderStructure ? .watchedFolder : .flat)
        let preservesSubfolderStructure = structure != .flat
        let pattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedTags = (finderTag.map { [$0] } ?? []) + finderTags
        let requestedExclusions = (excludedFinderTag.map { [$0] } ?? []) + excludedFinderTags
        let tags = Self.normalizedTagNames(requestedTags)
        let exclusions = Self.normalizedTagNames(requestedExclusions)
        let tagsToAdd = Self.normalizedTagNames(copyFinderTags)
        let tagsToRemove = Self.normalizedTagNames(removedCopyTags)
        let includedFolders = Self.normalizedFolderPattern(includedSubfolderPattern)
        let excludedFolders = Self.normalizedFolderPattern(excludedSubfolderPattern)
        let conditions = ConditionGroup(matchMode: matchMode, pattern: pattern, fileExtension: fileExtension,
                                        minimumBytes: minimumBytes,
                                        maximumBytes: maximumBytes, minimumAgeDays: minimumAgeDays,
                                        maximumAgeDays: maximumAgeDays, ageBasis: ageBasis, fileKind: fileKind,
                                        finderTags: requestedTags, contentsContains: contentsContains,
                                        recognizesText: recognizesText, groups: conditionGroups)
        guard conditions.isValid, conditions.hasConditions || (matchMode != .none && !exclusions.isEmpty),
              maximumSubfolderDepth.map({ includesSubfolders && $0 > 0 }) ?? true,
              !preservesSubfolderStructure || (destination != nil && !ignoresMatches && (includesSubfolders || structure == .immediateParent)),
              (includedFolders == nil && excludedFolders == nil) || includesSubfolders,
              Self.isValidSubfolderPattern(includedFolders), Self.isValidSubfolderPattern(excludedFolders),
              Self.isValidRenamePrefix(renamePrefix), requestedTags.allSatisfy({ Self.isValidFinderTag($0) }),
              requestedExclusions.allSatisfy({ Self.isValidFinderTag($0) }),
              (copyFinderTags + removedCopyTags).allSatisfy({ Self.isValidFinderTag($0) }),
              copyTagTemplates.allSatisfy({ $0.renderer() != nil }),
              copiesMatches || backup != nil || (tagsToAdd.isEmpty && tagsToRemove.isEmpty && copyTagTemplates.isEmpty),
              copiesMatches || (!copiesOnArrival && !skipsIdenticalCopies),
              renameTemplate == nil || (renamePrefix ?? "").isEmpty,
              let sourceFolder = AutomationDirectories.Folder(source)
        else { return nil }
        let destinationFolder: AutomationDirectories.Folder
        guard !copiesMatches || (destination != nil && !ignoresMatches) else { return nil }
        guard backup == nil || (!copiesMatches && !ignoresMatches) else { return nil }
        guard additionalBackups.isEmpty || backup != nil else { return nil }
        guard !numbersBackupConflicts || backup != nil else { return nil }
        if ignoresMatches {
            guard destination == nil, subfolderTemplate == nil, renameTemplate == nil,
                  (renamePrefix ?? "").isEmpty else { return nil }
            destinationFolder = sourceFolder
        } else if let destination {
            guard let folder = AutomationDirectories.Folder(destination), folder != sourceFolder else { return nil }
            destinationFolder = folder
        } else {
            guard subfolderTemplate != nil || renameTemplate != nil || !(renamePrefix ?? "").isEmpty else { return nil }
            destinationFolder = sourceFolder
        }
        if includesSubfolders {
            let root = NamingRules.key(sourceFolder.path)
            let target = NamingRules.key(destinationFolder.path)
            guard !target.hasPrefix(root + "/"), target != root || subfolderTemplate == nil else { return nil }
            if preservesSubfolderStructure, root.hasPrefix(target + "/") { return nil }
        }
        self.id = id
        self.directories = AutomationDirectories(source: sourceFolder, destination: destinationFolder,
                                                 allowsDestinationSubfolders: subfolderTemplate != nil || preservesSubfolderStructure)
        if let backup {
            guard let folder = AutomationDirectories.Folder(backup) else { return nil }
            backupFolder = folder
        } else {
            backupFolder = nil
        }
        let extraFolders = additionalBackups.compactMap(AutomationDirectories.Folder.init)
        guard extraFolders.count == additionalBackups.count else { return nil }
        additionalBackupFolders = extraFolders.isEmpty ? nil : extraFolders
        self.pattern = pattern
        self.fileExtension = conditions.fileExtension
        self.minimumBytes = minimumBytes
        self.maximumBytes = maximumBytes
        self.minimumAgeDays = minimumAgeDays
        self.maximumAgeDays = maximumAgeDays
        savedAgeBasis = (minimumAgeDays != nil || maximumAgeDays != nil) && ageBasis != .modified ? ageBasis : nil
        self.fileKind = fileKind
        self.contentsContains = conditions.contentsContains
        savedRecognizesText = recognizesText ? true : nil
        self.finderTag = tags.first
        self.excludedFinderTag = exclusions.first
        self.additionalFinderTags = tags.count > 1 ? Array(tags.dropFirst()) : nil
        self.additionalExcludedFinderTags = exclusions.count > 1 ? Array(exclusions.dropFirst()) : nil
        self.renamePrefix = renamePrefix.flatMap { $0.isEmpty ? nil : $0 }
        self.renameTemplate = renameTemplate
        self.subfolderTemplate = subfolderTemplate
        self.savedMatchMode = matchMode == .all ? nil : matchMode
        savedConditionGroups = conditionGroups.isEmpty ? nil : conditionGroups
        savedIgnoresMatches = ignoresMatches ? true : nil
        savedCopiesMatches = copiesMatches ? true : nil
        savedCopiesOnArrival = copiesOnArrival ? true : nil
        savedNotifiesOnCompletion = !ignoresMatches && notifiesOnCompletion ? true : nil
        savedCopyFinderTags = tagsToAdd.isEmpty ? nil : tagsToAdd
        savedCopyTagTemplates = copyTagTemplates.isEmpty ? nil : copyTagTemplates
        savedRemovedCopyTags = tagsToRemove.isEmpty ? nil : tagsToRemove
        savedSkipsIdenticalCopies = skipsIdenticalCopies ? true : nil
        savedCollisionPolicy = !ignoresMatches && collisionPolicy != .leaveInPlace ? collisionPolicy : nil
        savedNumbersBackupConflicts = numbersBackupConflicts ? true : nil
        savedIncludesSubfolders = includesSubfolders ? true : nil
        savedPreservesSubfolderStructure = structure == .watchedFolder ? true : nil
        savedFolderStructure = structure == .immediateParent ? structure : nil
        self.maximumSubfolderDepth = maximumSubfolderDepth
        self.includedSubfolderPattern = includedFolders
        self.excludedSubfolderPattern = excludedFolders
        self.enabled = enabled
        guard foldersAreUsable(env: env) else { return nil }
    }

    public struct File: Equatable, Sendable {
        public let name: String
        public let relativePath: String
        fileprivate let nestedSource: AutomationDirectories.Folder?
        public fileprivate(set) var destinationName: String
        public fileprivate(set) var renderedCopyTags: [String] = []
        fileprivate var destinationNumber: Int?
        fileprivate var backupNumbers: [Int?] = []
        fileprivate var destinationSubfolders: [String] = []
        fileprivate var dateAddedForDestination: Date?
        public var destinationRelativePath: String { (destinationSubfolders + [destinationName]).joined(separator: "/") }
        public var backupRelativePath: String {
            backupRelativePaths.first ?? relativePath
        }
        public var backupRelativePaths: [String] {
            backupNumbers.map { number in
                guard let number else { return relativePath }
                return String(relativePath.dropLast(name.count)) + FolderAutomationRule.numberedName(name, number: number)
            }
        }
        public let snapshot: ItemSnapshot
        fileprivate let created: Date?
        fileprivate init(name: String, info: stat, parent: AutomationDirectories.Folder, root: AutomationDirectories.Folder) {
            self.name = name
            nestedSource = parent == root ? nil : parent
            relativePath = parent == root ? name : String(parent.path.dropFirst(root.path.count + 1)) + "/" + name
            self.destinationName = name
            let birth = info.st_birthtimespec
            created = birth.tv_sec == 0 && birth.tv_nsec == 0 ? nil : AutomationDirectories.date(birth)
            self.snapshot = ItemSnapshot(fileID: UInt64(info.st_ino), bytes: Int64(info.st_blocks) * 512,
                                         modified: AutomationDirectories.date(info.st_mtimespec), identitySize: info.st_size,
                                         changed: AutomationDirectories.date(info.st_ctimespec))
        }
    }

    public struct EarlierRuleMatch: Sendable {
        public let relativePath: String
        public let ruleID: UUID
    }

    public enum FileMatch: Equatable, Sendable {
        case matches, earlierRule, doesNotMatch, unavailable
    }

    public struct ConditionCheck: Sendable {
        public let label: String
        public let value: String?
        public let result: Bool?
        public let children: [ConditionCheck]

        fileprivate init(label: String, value: String? = nil, result: Bool?, children: [ConditionCheck] = []) {
            self.label = label
            self.value = value
            self.result = result
            self.children = children
        }
    }

    public struct Observation: Sendable {
        public fileprivate(set) var files: [File] = []
        public fileprivate(set) var ignoredCount = 0
        public fileprivate(set) var ignoredExamples: [String] = []
        public fileprivate(set) var earlierRuleMatches = 0
        public fileprivate(set) var earlierRuleExamples: [EarlierRuleMatch] = []
        public fileprivate(set) var conflicts = 0
        public fileprivate(set) var backupConflicts = 0
        public fileprivate(set) var identicalCopies = 0
        public fileprivate(set) var namesTooLong = 0
        public fileprivate(set) var namesUnavailable = 0
        public fileprivate(set) var tagsUnavailable = 0
        public fileprivate(set) var destinationsUnavailable = 0
        public fileprivate(set) var fileMatch: FileMatch?
        public fileprivate(set) var conditionChecks: [ConditionCheck] = []
    }

    private static func normalizedFolderPattern(_ pattern: String?) -> String? {
        guard let value = pattern?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return value
    }

    public static func isValidSubfolderPattern(_ pattern: String?) -> Bool {
        guard let pattern = normalizedFolderPattern(pattern) else { return true }
        return !pattern.contains("/") && !pattern.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private func allowsSubfolder(named name: String) -> Bool {
        let included = includedSubfolderPattern.map { OrganizeRule.matchesName(name, pattern: $0) } ?? true
        let excluded = excludedSubfolderPattern.map { OrganizeRule.matchesName(name, pattern: $0) } ?? false
        return included && !excluded
    }

    public static func isValidRenamePrefix(_ prefix: String?) -> Bool {
        guard let prefix, !prefix.isEmpty else { return true }
        return !prefix.hasPrefix(".") && !prefix.contains("/") && !prefix.contains(":")
            && prefix.utf8.count < NAME_MAX
            && !prefix.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    public static func isValidFinderTag(_ tag: String?) -> Bool {
        tag?.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) != true
    }

    public static func isValidFileExtension(_ value: String?) -> Bool {
        value.map { normalizedFileExtension($0) != nil } ?? true
    }

    private static func normalizedFileExtension(_ value: String) -> String? {
        guard !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let suffix = trimmed.hasPrefix(".") ? trimmed.dropFirst() : trimmed[...]
        guard !suffix.isEmpty, !suffix.contains(where: { $0.isWhitespace || ".\\/:*?[]".contains($0) })
        else { return nil }
        return suffix.lowercased()
    }

    private static func normalizedTagNames(_ names: [String]) -> [String] {
        var keys: Set<String> = []
        return names.compactMap { name in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && keys.insert(NamingRules.key(trimmed)).inserted ? trimmed : nil
        }
    }

    private func copyTagRenderer() -> ((File) -> [String]?)? {
        let renderers = copyTagTemplates.compactMap { $0.renderer() }
        guard renderers.count == copyTagTemplates.count else { return nil }
        let fixed = copyFinderTags
        if renderers.isEmpty { return { _ in fixed } }
        return { file in
            var tags = fixed
            for render in renderers {
                guard let tag = render(file.name, file.created, file.snapshot.modified) else { return nil }
                tags.append(tag)
            }
            return Self.normalizedTagNames(tags)
        }
    }

    public func observe(env: ScanEnvironment) -> Observation? {
        Self.observe([self], env: env, now: Date())[id]
    }

    /// Read the source once and assign each file to its first match, even when that rule cannot move it.
    public static func observe(
        _ rules: [Self], env: ScanEnvironment, now: Date,
        duplicateFingerprints: AutomationDuplicateFingerprints = AutomationDuplicateFingerprints(),
        recognitionCache: AutomationRecognitionCache? = nil,
        lastOpened: (URL) -> Date? = LastUsedReader.liveLastUsed,
        trackingEarlierMatchesFor previewRuleID: UUID? = nil,
        previewingRelativePath: String? = nil,
        previewingIdentity: FileIdentity? = nil,
        requiresVerifiedFinderTags: Bool = false,
        excluding: (File) -> Bool = { _ in false }
    ) -> [UUID: Observation] {
        guard let folder = rules.first?.directories.source, let source = folder.openCurrent() else { return [:] }
        defer { close(source) }
        let applicable = rules.filter { $0.directories.source == folder }
        var destinations: [UUID: (fd: Int32, name: (File) -> String?, subfolders: (File, [String]) -> [String]?,
                                  copyTags: (File) -> [String]?)] = [:]
        var backups: [UUID: [(folder: AutomationDirectories.Folder, fd: Int32)]] = [:]
        var results: [UUID: Observation] = [:]
        defer {
            for destination in destinations.values { close(destination.fd) }
            for group in backups.values {
                for backup in group { close(backup.fd) }
            }
        }
        for rule in applicable where rule.foldersAreUsable(env: env) {
            if !rule.ignoresMatches {
                guard let render = rule.filenameRenderer(), let subfolders = rule.subfolderRenderer(),
                      let copyTags = rule.copyTagRenderer(),
                      let fd = rule.directories.destination.openCurrent() else { continue }
                let folders = rule.backupFolders
                let opened = folders.compactMap { folder in folder.openCurrent().map { (folder, $0) } }
                guard opened.count == folders.count else {
                    close(fd)
                    for (_, descriptor) in opened { close(descriptor) }
                    continue
                }
                if !opened.isEmpty { backups[rule.id] = opened }
                destinations[rule.id] = (fd, render, subfolders, copyTags)
            }
            results[rule.id] = Observation()
        }
        guard !results.isEmpty else { return [:] }
        let previewComponents = previewingRelativePath?.components(separatedBy: "/")
        if let previewComponents {
            guard let previewRuleID, results[previewRuleID] != nil,
                  previewComponents.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") }) else { return [:] }
            results[previewRuleID]?.fileMatch = .unavailable
        }
        let folderChecks = DestinationGuard.ObservationCache()
        let needsReservations = applicable.contains {
            $0.includesSubfolders || $0.renameTemplate != nil || $0.subfolderTemplate != nil
                || $0.renamePrefix != nil || $0.collisionPolicy == .numberIncoming || $0.backupFolder != nil
        }
        var reservedNames: [String: Set<String>] = [:]
        var nextNumbers: [String: Int] = [:]
        var numberedCopyNames: [String: [String: [Int]]] = [:]
        var usableSubfolders: [String: Bool] = [:]
        typealias Matcher = (rule: Self, conditions: ConditionMatcher, exclusions: [String])
        typealias PendingFolder = (folder: AutomationDirectories.Folder, depth: Int, matchers: [Matcher])
        let allMatchers: [Matcher] = applicable.compactMap { rule in
            let group = rule.conditionGroup
            guard group.isValid else { return nil }
            return (rule, ConditionMatcher(group), rule.excludedFinderTags.map(NamingRules.key))
        }
        let mayRecognizeText = allMatchers.contains { $0.conditions.recognizesText }
        var pending: [PendingFolder] = [(folder, 0, allMatchers)]
        while let (parent, depth, matchers) = pending.popLast() {
            guard let parentFD = parent == folder ? source : parent.openCurrent() else { continue }
            defer { if parent != folder { close(parentFD) } }
            let relativeParent = parent == folder ? [] : parent.path.dropFirst(folder.path.count + 1).components(separatedBy: "/")
            var parentInfo = stat()
            guard fstat(parentFD, &parentInfo) == 0 else {
                if parent == folder { return [:] }
                continue
            }
            let names: [String]
            if let previewComponents {
                guard depth < previewComponents.count else { continue }
                names = [previewComponents[depth]]
            } else if let children = try? ArchiveTree.children(parentFD, path: parent.path) {
                names = children.sorted()
            } else {
                if parent == folder { return [:] }
                continue
            }
            let descending = matchers.filter { $0.rule.watchedDepthLimit.map { depth < $0 } ?? true }
            let previewIndex = previewRuleID.flatMap { id in
                results[id] == nil ? nil : matchers.firstIndex { $0.rule.id == id }
            }
            var children: [PendingFolder] = []
            for name in names where !name.hasPrefix(".") {
                var info = stat()
                guard fstatat(parentFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                      info.st_dev == parentInfo.st_dev, info.st_uid == getuid(),
                      info.st_flags & UInt32(SF_DATALESS | UF_HIDDEN) == 0 else { continue }
                let url = parent.url.appendingPathComponent(name)
                if info.st_mode & S_IFMT == S_IFDIR {
                    if let previewComponents, depth == previewComponents.count - 1 { continue }
                    let eligible = descending.filter { $0.rule.allowsSubfolder(named: name) }
                    // Keep unavailable rules for priority, but only enter branches that have a usable rule.
                    guard eligible.contains(where: { results[$0.rule.id] != nil }),
                          let nested = Self.approvedSubfolder(url, info: info, root: folder, env: env,
                                                              cache: folderChecks) else { continue }
                    children.append((nested, depth + 1, eligible))
                    continue
                }
                guard info.st_mode & S_IFMT == S_IFREG else { continue }
                if let previewComponents {
                    guard depth == previewComponents.count - 1,
                          previewingIdentity == nil || previewingIdentity == FileIdentity(dev: info.st_dev, ino: info.st_ino)
                    else { continue }
                }
                var file = File(name: name, info: info, parent: parent, root: folder)
                guard previewComponents != nil || !excluding(file) else { continue }
                var detectedKind: Kind??
                var tagKeys: Set<String>??
                var addedDate: Date??
                var openedDate: Date??
                var fileContents: AutomationContents??
                var recognizedText: [String]?
                func kind() -> Kind? {
                    if let detectedKind { return detectedKind }
                    let value = KindClassifier.kind(named: name)
                    detectedKind = .some(value)
                    return value
                }
                func hasTag(_ key: String) -> Bool? {
                    if tagKeys == nil {
                        if requiresVerifiedFinderTags {
                            let tags = AutomationFinderTags.readNames(name, in: parentFD, expected: info)
                            tagKeys = .some(tags.map { Set($0.map(NamingRules.key)) })
                        } else if let values = try? url.resourceValues(forKeys: [.tagNamesKey]) {
                            tagKeys = .some(Set((values.tagNames ?? []).map(NamingRules.key)))
                        } else {
                            tagKeys = .some(nil)
                        }
                    }
                    return (tagKeys ?? nil)?.contains(key)
                }
                func dateAdded() -> Date? {
                    // Finder may return an inconsistent Date Added for hard links.
                    guard info.st_nlink == 1 else { return nil }
                    if let addedDate { return addedDate }
                    let date = (try? url.resourceValues(forKeys: [.addedToDirectoryDateKey]))?.addedToDirectoryDate
                    addedDate = .some(date)
                    return date
                }
                func dateOpened() -> Date? {
                    if let openedDate { return openedDate }
                    let date = lastOpened(url)
                    openedDate = .some(date)
                    return date
                }
                func containsText(_ phrase: String, recognizesText: Bool) -> Bool? {
                    if fileContents == nil {
                        fileContents = .some(AutomationContents.read(name: name, at: url, in: parentFD,
                                                                     expected: info, mayRecognizeText: mayRecognizeText))
                    }
                    guard let contents = fileContents ?? nil else { return nil }
                    if let found = contents.contains(phrase) { return found }
                    guard recognizesText else { return nil }
                    if recognizedText == nil {
                        recognizedText = recognitionCache?.text(for: info, extension: url.pathExtension.lowercased(),
                                                                read: contents.recognizeText) ?? contents.recognizeText()
                    }
                    // Vision can miss a phrase even when it reads other text in the image.
                    return AutomationContents.contains(phrase, in: recognizedText ?? []) ? true : nil
                }
                func matches(_ matcher: Matcher, record: ((ConditionCheck) -> Void)? = nil) -> Bool? {
                    var condition: Bool? = true
                    if matcher.conditions.group.hasConditions {
                        condition = matcher.conditions.matches(file, kind: kind, hasTag: hasTag,
                                                               dateAdded: dateAdded, dateOpened: dateOpened,
                                                               containsText: containsText, now: now, record: record)
                        if !requiresVerifiedFinderTags && condition == nil { condition = false }
                        if condition == false && record == nil { return false }
                    } else if matcher.rule.matchMode == .none || matcher.exclusions.isEmpty {
                        return false
                    }
                    // The exclusion applies to every match mode and requires a successful tag read.
                    var unreadableExclusion = false
                    for (tag, key) in zip(matcher.rule.excludedFinderTags, matcher.exclusions) {
                        let excluded = hasTag(key)
                        record?(.init(label: "Doesn’t have Finder tag “\(tag)”", result: excluded.map { !$0 }))
                        if excluded == true {
                            if record == nil { return false }
                            condition = false
                        }
                        if excluded == nil { unreadableExclusion = true }
                    }
                    return unreadableExclusion && condition != false ? nil : condition
                }
                var winner: Int?
                for (index, matcher) in matchers.enumerated() {
                    let matched = matches(matcher)
                    if matched == true { winner = index; break }
                    // Unknown tags on an earlier rule must not send the file to a later destination.
                    if requiresVerifiedFinderTags, matched == nil, case .some(.none) = tagKeys { break }
                }
                if previewComponents != nil {
                    guard let previewRuleID, let previewIndex,
                          !incompleteExtensions.contains(url.pathExtension.lowercased()),
                          !SafetyGuard.isPackage(url), !FolderPlanner.liveIsUbiquitous(url) else { continue }
                    var checks: [ConditionCheck] = []
                    let matchesPreview = matches(matchers[previewIndex], record: { checks.append($0) }) == true
                    results[previewRuleID]?.conditionChecks = checks
                    if matchesPreview, let winner, winner < previewIndex {
                        results[previewRuleID]?.fileMatch = .earlierRule
                    } else {
                        results[previewRuleID]?.fileMatch = matchesPreview ? .matches : .doesNotMatch
                    }
                    continue
                }
                guard let winningIndex = winner else { continue }
                let rule = matchers[winningIndex].rule
                let canPlan = results[rule.id] != nil
                let earlierThanPreview = previewIndex.map { winningIndex < $0 } ?? false
                guard canPlan || earlierThanPreview else { continue }
                guard !incompleteExtensions.contains(url.pathExtension.lowercased()),
                      !SafetyGuard.isPackage(url), !FolderPlanner.liveIsUbiquitous(url) else { continue }
                if let previewIndex, earlierThanPreview, matches(matchers[previewIndex]) == true {
                    let draftID = matchers[previewIndex].rule.id
                    results[draftID]?.earlierRuleMatches += 1
                    if (results[draftID]?.earlierRuleExamples.count ?? 0) < 5 {
                        results[draftID]?.earlierRuleExamples.append(.init(relativePath: file.relativePath, ruleID: rule.id))
                    }
                }
                guard canPlan else { continue }
                if rule.ignoresMatches {
                    results[rule.id]?.ignoredCount += 1
                    if (results[rule.id]?.ignoredExamples.count ?? 0) < 5 { results[rule.id]?.ignoredExamples.append(file.relativePath) }
                    continue
                }
                guard let destination = destinations[rule.id] else { continue }
                if rule.changesCopyTags {
                    guard let tags = destination.copyTags(file) else {
                        results[rule.id]?.tagsUnavailable += 1
                        continue
                    }
                    file.renderedCopyTags = tags
                }
                if rule.renamesInPlace, let prefix = rule.renamePrefix,
                   NamingRules.key(name).hasPrefix(NamingRules.key(prefix)) { continue }
                if rule.subfolderTemplate?.needsDateAdded == true { file.dateAddedForDestination = dateAdded() }
                guard let target = destination.name(file),
                      let subfolders = destination.subfolders(file, relativeParent) else {
                    results[rule.id]?.namesUnavailable += 1
                    continue
                }
                if rule.renamesInPlace, NamingRules.key(target) == NamingRules.key(name) { continue }
                if rule.generatedNameIsTooLong(target, original: name) {
                    results[rule.id]?.namesTooLong += 1
                    continue
                }
                let renameHere = parent != folder && rule.renamesInPlace
                file.destinationSubfolders = renameHere ? relativeParent : subfolders
                let parentURL = renameHere ? parent.url : rule.destinationFolder(subfolders)
                let destinationKey = parentURL.path
                if !subfolders.isEmpty {
                    guard destinationKey.utf8.count + target.utf8.count + 1 < PATH_MAX else {
                        results[rule.id]?.namesTooLong += 1
                        continue
                    }
                    let usable = usableSubfolders[destinationKey] ?? rule.directories.usableGeneratedFolder(parentURL, env: env)
                    usableSubfolders[destinationKey] = usable
                    guard usable else { results[rule.id]?.destinationsUnavailable += 1; continue }
                }
                let targetFD = renameHere ? parentFD : subfolders.isEmpty ? destination.fd
                    : AutomationDirectories.openSubfolders(subfolders, below: destination.fd, create: false)
                if targetFD < 0, errno != ENOENT {
                    results[rule.id]?.destinationsUnavailable += 1
                    continue
                }
                defer { if targetFD >= 0, !subfolders.isEmpty { close(targetFD) } }
                let reservationKey = needsReservations ? NamingRules.key(destinationKey) : destinationKey
                if rule.skipsIdenticalCopies, targetFD >= 0 {
                    func isIdentical(_ candidate: String) -> Bool {
                        var existing = stat()
                        return fstatat(targetFD, candidate, &existing, AT_SYMLINK_NOFOLLOW) == 0
                            && duplicateFingerprints.matches(
                                source: (parentFD, url.path, name, info),
                                destination: (targetFD, parentURL.appendingPathComponent(candidate).path, candidate, existing))
                    }
                    var identical = isIdentical(target)
                    if !identical, rule.collisionPolicy == .numberIncoming {
                        let numbered = numberedCopyNames[destinationKey] ?? Self.indexNumberedCopies(targetFD, path: destinationKey)
                        numberedCopyNames[destinationKey] = numbered
                        identical = numbered[NamingRules.key(target)]?.contains {
                            isIdentical(Self.numberedName(target, number: $0))
                        } == true
                    }
                    if identical {
                        results[rule.id]?.identicalCopies += 1
                        continue
                    }
                }
                let destinationName = Self.availableName(target, in: destinationKey, fd: targetFD, key: reservationKey,
                    reserved: reservedNames[reservationKey, default: []], numbered: rule.collisionPolicy == .numberIncoming,
                    nextNumbers: &nextNumbers)
                file.destinationName = destinationName.name
                file.destinationNumber = destinationName.number
                switch destinationName.state {
                case .occupied:
                    results[rule.id]?.conflicts += 1
                case .available:
                    if let targets = backups[rule.id] {
                        var placements: [(key: String, name: String, number: Int?)] = []
                        var backupNextNumbers = nextNumbers
                        for (base, backupFD) in targets {
                            let path = Self.backupParent(base, relativeParent)
                            let key = NamingRules.key(path.path)
                            guard path.path.utf8.count + file.name.utf8.count + 1 < PATH_MAX else {
                                results[rule.id]?.namesTooLong += 1
                                break
                            }
                            let guardDirectories = AutomationDirectories(
                                source: parent, destination: base, allowsDestinationSubfolders: !relativeParent.isEmpty)
                            if !relativeParent.isEmpty {
                                let usable = usableSubfolders[key] ?? guardDirectories.usableGeneratedFolder(path, env: env)
                                usableSubfolders[key] = usable
                                guard usable else { results[rule.id]?.destinationsUnavailable += 1; break }
                            }
                            let fd = relativeParent.isEmpty ? backupFD
                                : AutomationDirectories.openSubfolders(relativeParent, below: backupFD, create: false)
                            guard fd >= 0 || errno == ENOENT else { results[rule.id]?.destinationsUnavailable += 1; break }
                            defer { if fd >= 0, !relativeParent.isEmpty { close(fd) } }
                            let name = Self.availableName(file.name, in: path.path, fd: fd, key: key,
                                reserved: reservedNames[key, default: []], numbered: rule.numbersBackupConflicts,
                                nextNumbers: &backupNextNumbers)
                            switch name.state {
                            case .available: placements.append((key, name.name, name.number)); continue
                            case .occupied: results[rule.id]?.backupConflicts += 1
                            case .tooLong: results[rule.id]?.namesTooLong += 1
                            case .unavailable: results[rule.id]?.destinationsUnavailable += 1
                            }
                            break
                        }
                        guard placements.count == targets.count else { continue }
                        nextNumbers = backupNextNumbers
                        file.backupNumbers = placements.map(\.number)
                        for placement in placements {
                            reservedNames[placement.key, default: []].insert(NamingRules.key(placement.name))
                        }
                    }
                    if needsReservations { reservedNames[reservationKey, default: []].insert(NamingRules.key(file.destinationName)) }
                    results[rule.id]?.files.append(file)
                case .tooLong:
                    results[rule.id]?.namesTooLong += 1
                case .unavailable:
                    results[rule.id]?.destinationsUnavailable += 1
                }
            }
            pending.append(contentsOf: children.reversed())
        }
        return results
    }

    private static func backupParent(_ folder: AutomationDirectories.Folder, _ relativeParent: [String]) -> URL {
        relativeParent.reduce(folder.url) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    private static func approvedSubfolder(
        _ url: URL, info: stat, root: AutomationDirectories.Folder, env: ScanEnvironment,
        cache: DestinationGuard.ObservationCache
    ) -> AutomationDirectories.Folder? {
        guard !SafetyGuard.isPackage(url), !FolderPlanner.liveIsUbiquitous(url),
              DestinationGuard.check(url, env: env, cloudRoots: [], isUbiquitous: FolderPlanner.liveIsUbiquitous,
                                     deviceOf: { FileIdentity(path: $0.path)?.dev }, pickedFolder: root.url,
                                     cache: cache) == .usable,
              let folder = AutomationDirectories.Folder(url), let descriptor = folder.openCurrent() else { return nil }
        defer { close(descriptor) }
        var current = stat()
        guard fstat(descriptor, &current) == 0, current.st_dev == info.st_dev, current.st_ino == info.st_ino,
              current.st_birthtimespec.tv_sec == info.st_birthtimespec.tv_sec,
              current.st_birthtimespec.tv_nsec == info.st_birthtimespec.tv_nsec else { return nil }
        return folder
    }

    private struct ConditionMatcher {
        let group: ConditionGroup
        let filename: OrganizeRule?
        let fileExtension: String?
        let tags: [String]
        let children: [ConditionMatcher]
        var recognizesText: Bool { group.recognizesText || children.contains(where: \.recognizesText) }

        init(_ group: ConditionGroup) {
            self.group = group
            filename = group.pattern.isEmpty ? nil : OrganizeRule(pattern: group.pattern, destination: .relative(["unused"]))
            fileExtension = group.fileExtension.flatMap(FolderAutomationRule.normalizedFileExtension)
            tags = group.finderTags.map(NamingRules.key)
            children = group.groups.map(ConditionMatcher.init)
        }

        func matches(_ file: File, kind: () -> Kind?, hasTag: (String) -> Bool?, dateAdded: () -> Date?,
                     dateOpened: () -> Date?,
                     containsText: (String, Bool) -> Bool?, now: Date,
                     record: ((ConditionCheck) -> Void)? = nil) -> Bool? {
            let decisiveInput = group.matchMode != .all
            let decisiveOutput = group.matchMode == .any
            var foundDecisive = false
            var unknown = false
            func checked(_ result: Bool?, _ label: @autoclosure () -> String,
                         value: @autoclosure () -> String? = nil, children: [ConditionCheck] = []) -> Bool {
                record?(.init(label: label(), value: value(), result: result, children: children))
                guard let result else { unknown = true; return false }
                guard result == decisiveInput else { return false }
                foundDecisive = true
                return record == nil
            }
            if let filename, checked(filename.matches(fileName: file.name, kind: nil),
                                     "Filename matches “\(group.pattern)”", value: file.name) { return decisiveOutput }
            if let fileExtension {
                let actual = (file.name as NSString).pathExtension
                if checked(actual.lowercased() == fileExtension, "Extension is .\(fileExtension)",
                           value: actual.isEmpty ? "No extension" : ".\(actual)") { return decisiveOutput }
            }
            if group.minimumBytes != nil || group.maximumBytes != nil {
                let size = file.snapshot.identitySize ?? 0
                if checked(size >= (group.minimumBytes ?? 0) && size <= (group.maximumBytes ?? .max),
                           "File size \(Self.range(group.minimumBytes.map(ByteFormat.string), group.maximumBytes.map(ByteFormat.string)))",
                           value: ByteFormat.string(size)) { return decisiveOutput }
            }
            if group.minimumAgeDays != nil || group.maximumAgeDays != nil {
                let (date, label): (Date?, String) = switch group.ageBasis {
                case .modified: (file.snapshot.modified, "Last modified")
                case .created: (file.created, "Created")
                case .added: (dateAdded(), "Added to folder")
                case .opened: (dateOpened(), "Last opened")
                }
                let ageMatches = date.map { value in
                    let age = now.timeIntervalSince(value)
                    return (group.minimumAgeDays.map { age >= Double($0) * 86_400 } ?? true)
                        && (group.maximumAgeDays.map { age <= Double($0) * 86_400 } ?? true)
                }
                if checked(ageMatches,
                           "\(label) \(Self.range(group.minimumAgeDays.map { "\($0) days" }, group.maximumAgeDays.map { "\($0) days" })) ago",
                           value: date?.formatted(date: .abbreviated, time: .shortened)) { return decisiveOutput }
            }
            if let fileKind = group.fileKind {
                let actual = kind()
                if checked(actual.map { $0 == fileKind }, "Kind is \(fileKind.folderName)",
                           value: actual?.folderName) { return decisiveOutput }
            }
            for (tag, key) in zip(group.finderTags, tags) {
                if checked(hasTag(key), "Has Finder tag “\(tag)”") { return decisiveOutput }
            }
            for child in children {
                var nested: [ConditionCheck] = []
                let childRecord: ((ConditionCheck) -> Void)? = record == nil ? nil : { nested.append($0) }
                let matched = child.matches(file, kind: kind, hasTag: hasTag, dateAdded: dateAdded, dateOpened: dateOpened,
                                            containsText: containsText, now: now, record: childRecord)
                if checked(matched, child.groupLabel, children: nested) { return decisiveOutput }
            }
            if let phrase = group.contentsContains,
               checked(containsText(phrase, group.recognizesText), "Contents contain “\(phrase)”") { return decisiveOutput }
            if foundDecisive { return decisiveOutput }
            return unknown ? nil : !decisiveOutput
        }

        private var groupLabel: String {
            switch group.matchMode {
            case .all: return "All conditions in this group"
            case .any: return "Any condition in this group"
            case .none: return "No condition in this group"
            }
        }

        private static func range(_ minimum: String?, _ maximum: String?) -> String {
            if let minimum, let maximum { return "between \(minimum) and \(maximum)" }
            if let minimum { return "at least \(minimum)" }
            return "at most \(maximum ?? "")"
        }
    }

    public func plan(_ files: [File]) -> OrganizePlan {
        if ignoresMatches { return OrganizePlan(title: directories.source.url.lastPathComponent, steps: [], leftAlone: []) }
        let render = filenameRenderer()
        let subfolders = subfolderRenderer()
        let renderTags = copyTagRenderer()
        let steps = files.flatMap { file -> [PlannedStep] in
            let parent = file.nestedSource ?? directories.source
            let renameHere = file.nestedSource != nil && renamesInPlace
            let relativeParent: [String]
            if file.nestedSource != nil {
                let prefix = directories.source.path + "/"
                guard parent.path.hasPrefix(prefix) else { return [] }
                relativeParent = parent.path.dropFirst(prefix.count).components(separatedBy: "/")
            } else {
                relativeParent = []
            }
            guard let base = render?(file), !generatedNameIsTooLong(base, original: file.name),
                  watchedDepthLimit.map({ relativeParent.count <= $0 }) ?? true,
                  relativeParent.allSatisfy(allowsSubfolder(named:)),
                  let renderedFolders = subfolders?(file, relativeParent),
                  renderedFolders.isEmpty || directories.allowsDestinationSubfolders,
                  file.destinationSubfolders == (renameHere ? relativeParent : renderedFolders),
                  !renamesInPlace || file.name != file.destinationName else { return [] }
            let target: String
            if let number = file.destinationNumber {
                guard collisionPolicy == .numberIncoming, Self.numberedDestinations.contains(number) else { return [] }
                target = Self.numberedName(base, number: number)
                guard target.utf16.count <= NAME_MAX else { return [] }
            } else { target = base }
            guard file.destinationName == target else { return [] }
            let from = parent.url.appendingPathComponent(file.name)
            let to = (renameHere ? parent.url : destinationFolder(renderedFolders)).appendingPathComponent(file.destinationName)
            guard let tags = renderTags?(file) else { return [] }
            var step = PlannedStep(action: copiesMatches ? .copy(from: from, to: to) : .move(from: from, to: to),
                                   snapshot: file.snapshot, catalogEntryID: OrganizeCatalogID.automation, provider: nil)
            if copiesMatches {
                step.copyFinderTags = tags
                step.removedCopyTags = removedCopyTags
            }
            if file.nestedSource != nil || (directories.allowsDestinationSubfolders && renderedFolders.isEmpty) {
                step.automationDirectories = AutomationDirectories(
                    source: parent, destination: renameHere ? parent : directories.destination,
                    allowsDestinationSubfolders: !renameHere && !renderedFolders.isEmpty,
                    sourceBoundary: file.nestedSource == nil ? nil : directories.source
                )
            }
            let folders = backupFolders
            guard folders.count == file.backupNumbers.count,
                  file.backupNumbers.compactMap({ $0 }).allSatisfy({
                      numbersBackupConflicts && Self.numberedDestinations.contains($0)
                  }) else { return [] }
            var chain: [PlannedStep] = []
            for (folder, relativePath) in zip(folders, file.backupRelativePaths) {
                let backup = folder.url.appendingPathComponent(relativePath)
                var copy = PlannedStep(action: .copy(from: from, to: backup), snapshot: file.snapshot,
                                       catalogEntryID: OrganizeCatalogID.automation, provider: nil)
                copy.copyFinderTags = tags
                copy.removedCopyTags = removedCopyTags
                copy.automationDirectories = AutomationDirectories(
                    source: parent, destination: folder, allowsDestinationSubfolders: !relativeParent.isEmpty,
                    sourceBoundary: file.nestedSource == nil ? nil : directories.source)
                copy.requiredCopyID = chain.last?.id
                chain.append(copy)
            }
            step.requiredCopyID = chain.last?.id
            chain.append(step)
            return chain
        }
        var plan = OrganizePlan(title: directories.source.url.lastPathComponent, steps: steps, leftAlone: [])
        plan.automationDirectories = directories
        return plan
    }

    /// Verify that each worker step copies the observed file to its planned leaf within the approved roots.
    public func validatesBackgroundCopy(_ plan: OrganizePlan, for files: [File]) -> Bool {
        guard copiesMatches, !ignoresMatches, directories.source != directories.destination,
              directories.sourceBoundary == nil, subfolderTemplate == nil, folderStructure != .immediateParent,
              directories.allowsDestinationSubfolders == (folderStructure == .watchedFolder),
              backupFolders.isEmpty, plan.volume == nil, plan.automationDirectories == directories,
              plan.steps.count == files.count, let renderTags = copyTagRenderer() else { return false }

        for (step, file) in zip(plan.steps, files) {
            let parts = file.relativePath.components(separatedBy: "/")
            let parents = Array(parts.dropLast())
            guard parts.last == file.name, parents.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && !$0.utf8.contains(0) }),
                  watchedDepthLimit.map({ parents.count <= $0 }) ?? true,
                  parents.allSatisfy(allowsSubfolder(named:)),
                  parents.isEmpty == (file.nestedSource == nil) else { return false }
            let source = file.nestedSource ?? directories.source
            let sourcePath = parents.reduce(directories.source.url) { $0.appendingPathComponent($1, isDirectory: true) }
            let expectedParents = folderStructure == .watchedFolder ? parents : []
            let expected = AutomationDirectories(source: source, destination: directories.destination,
                                                 allowsDestinationSubfolders: !expectedParents.isEmpty,
                                                 sourceBoundary: parents.isEmpty ? nil : directories.source)
            let approved = step.automationDirectories ?? directories
            guard source.path == sourcePath.path, file.destinationSubfolders == expectedParents, approved == expected,
                  step.snapshot == file.snapshot, step.catalogEntryID == OrganizeCatalogID.automation,
                  step.provider == nil, step.groupID == nil, step.requiredCopyID == nil,
                  let tags = renderTags(file), step.copyFinderTags == tags, step.removedCopyTags == removedCopyTags,
                  case .copy(let from, let to) = step.action,
                  AutomationDirectories.filename(from.path, inside: source) == file.name,
                  let target = approved.destinationParts(to.path), target.folders == expectedParents,
                  target.name == file.destinationName else { return false }
        }
        return true
    }

    private enum DestinationAvailability { case available, occupied, tooLong, unavailable }
    private static let numberedDestinations = 2...999

    private static func availableName(
        _ name: String, in path: String, fd: Int32, key: String, reserved: Set<String>, numbered: Bool,
        nextNumbers: inout [String: Int]
    ) -> (state: DestinationAvailability, name: String, number: Int?) {
        func availability(_ candidate: String) -> DestinationAvailability {
            if !reserved.isEmpty, reserved.contains(NamingRules.key(candidate)) { return .occupied }
            if fd < 0 { return .available }
            var existing = stat()
            if fstatat(fd, candidate, &existing, AT_SYMLINK_NOFOLLOW) == 0 { return .occupied }
            switch errno {
            case ENOENT: return .available
            case ENAMETOOLONG: return .tooLong
            default: return .unavailable
            }
        }
        let initial = availability(name)
        guard numbered, initial == .occupied else { return (initial, name, nil) }
        let numberKey = key + "/" + NamingRules.key(name)
        var number = nextNumbers[numberKey] ?? 2
        while numberedDestinations.contains(number) {
            let candidate = numberedName(name, number: number)
            guard candidate.utf16.count <= NAME_MAX, path.utf8.count + candidate.utf8.count + 1 < PATH_MAX else {
                return (.tooLong, name, nil)
            }
            let state = availability(candidate)
            nextNumbers[numberKey] = number + 1
            if state != .occupied { return (state, candidate, state == .available ? number : nil) }
            number += 1
        }
        return (.occupied, name, nil)
    }

    private static func numberedName(_ name: String, number: Int) -> String {
        let path = name as NSString
        let extensionName = path.pathExtension
        return extensionName.isEmpty ? "\(name) \(number)" : "\(path.deletingPathExtension) \(number).\(extensionName)"
    }

    private static func indexNumberedCopies(_ directory: Int32, path: String) -> [String: [Int]] {
        guard let names = try? ArchiveTree.children(directory, path: path) else { return [:] }
        var result: [String: [Int]] = [:]
        for name in names where !name.hasPrefix(".") {
            func record(stem: String, suffix: String) {
                guard let separator = stem.lastIndex(of: " "),
                      let number = Int(stem[stem.index(after: separator)...]),
                      numberedDestinations.contains(number) else { return }
                let base = String(stem[..<separator]) + suffix
                guard numberedName(base, number: number) == name else { return }
                result[NamingRules.key(base), default: []].append(number)
            }
            record(stem: name, suffix: "")
            let filename = name as NSString
            if !filename.pathExtension.isEmpty {
                record(stem: filename.deletingPathExtension, suffix: "." + filename.pathExtension)
            }
        }
        return result
    }

    private func subfolderRenderer() -> ((File, [String]) -> [String]?)? {
        guard preservesSubfolderStructure || subfolderTemplate != nil else { return { _, _ in [] } }
        let generated: (File) -> [String]?
        if let subfolderTemplate {
            guard let render = subfolderTemplate.renderer() else { return nil }
            generated = { render($0.name, $0.created, $0.snapshot.modified, $0.dateAddedForDestination) }
        } else {
            generated = { _ in [] }
        }
        return { file, parents in
            let kept: [String]
            switch folderStructure {
            case .flat: kept = []
            case .watchedFolder: kept = parents
            case .immediateParent: kept = [parents.last ?? directories.source.url.lastPathComponent]
            }
            guard kept.allSatisfy(AutomationSubfolderTemplate.isFolderComponent), let generated = generated(file) else { return nil }
            return kept + generated
        }
    }

    private func destinationFolder(_ subfolders: [String]) -> URL {
        subfolders.reduce(directories.destination.url) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    private func filenameRenderer() -> ((File) -> String?)? {
        guard Self.isValidRenamePrefix(renamePrefix) else { return nil }
        if let renameTemplate {
            guard renamePrefix == nil, let render = renameTemplate.renderer() else { return nil }
            return { render($0.name, $0.created, $0.snapshot.modified) }
        }
        let prefix = renamePrefix ?? ""
        return { prefix + $0.name }
    }

    private func generatedNameIsTooLong(_ name: String, original: String) -> Bool {
        guard name != original else { return false }
        // Template output can include APFS names that fit in UTF-16 but take more than 255 UTF-8 bytes.
        // The destination lookup also checks the actual filesystem limit.
        let count = renameTemplate == nil ? name.utf8.count : name.utf16.count
        return count > NAME_MAX
    }

    private static let incompleteExtensions: Set<String> = ["download", "crdownload", "part", "partial", "tmp"]

    private func foldersAreUsable(env: ScanEnvironment) -> Bool {
        let source = directories.source.url, destination = directories.destination.url
        if preservesSubfolderStructure {
            let from = NamingRules.key(source.path), to = NamingRules.key(destination.path)
            guard includesSubfolders || folderStructure == .immediateParent, !ignoresMatches, directories.allowsDestinationSubfolders,
                  from != to, !from.hasPrefix(to + "/"), !to.hasPrefix(from + "/") else { return false }
        }
        guard let from = GroupPlanner.rulePath(of: source, env: env), !from.isEmpty,
              let to = GroupPlanner.rulePath(of: destination, env: env), !to.isEmpty,
              !from.split(separator: "/").contains(where: { $0.hasPrefix(".") }),
              !to.split(separator: "/").contains(where: { $0.hasPrefix(".") }),
              OrganizeGuard.driveRoot(containing: source, env: env) == nil,
              OrganizeGuard.driveRoot(containing: destination, env: env) == nil,
              let home = FileIdentity(path: env.home.path),
              FileIdentity(path: source.path)?.dev == home.dev,
              FileIdentity(path: destination.path)?.dev == home.dev else { return false }
        var otherFolders = Set([NamingRules.key(source.path), NamingRules.key(destination.path)])
        if backupFolder == nil, additionalBackupFolders?.isEmpty == false { return false }
        for folder in backupFolders {
            let backup = folder.url
            let key = NamingRules.key(backup.path)
            guard !copiesMatches, !ignoresMatches,
                  let path = GroupPlanner.rulePath(of: backup, env: env), !path.isEmpty,
                  !path.split(separator: "/").contains(where: { $0.hasPrefix(".") }),
                  OrganizeGuard.driveRoot(containing: backup, env: env) == nil,
                  FileIdentity(path: backup.path)?.dev == home.dev,
                  otherFolders.allSatisfy({ key != $0 && !key.hasPrefix($0 + "/") && !$0.hasPrefix(key + "/") }),
                  DestinationGuard.check(backup, env: env, cloudRoots: [], isUbiquitous: FolderPlanner.liveIsUbiquitous,
                                         deviceOf: { FileIdentity(path: $0.path)?.dev },
                                         pickedFolder: source) == .usable else { return false }
            otherFolders.insert(key)
        }
        if ignoresMatches {
            guard source == destination, subfolderTemplate == nil, renameTemplate == nil, renamePrefix == nil else { return false }
        }
        guard !changesCopyTags || copiesMatches || backupFolder != nil else { return false }
        if source == destination {
            guard ignoresMatches || subfolderTemplate != nil || renameTemplate != nil || !(renamePrefix ?? "").isEmpty,
                  !OrganizeGuard.holdsAppDatabase(source.path) else { return false }
        }
        // The existing Organize policy also detects synced Desktop/Documents, packages, libraries and projects.
        return [source, destination].allSatisfy {
            DestinationGuard.check($0, env: env, cloudRoots: [], isUbiquitous: FolderPlanner.liveIsUbiquitous,
                                   deviceOf: { FileIdentity(path: $0.path)?.dev },
                                   pickedFolder: $0 == source ? destination : source) == .usable
        }
    }
}

extension AutomationDirectories {
    static func filename(_ path: String, inside folder: Folder) -> String? {
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0),
              path == folder.url.appendingPathComponent(name).path else { return nil }
        return name
    }

    func destinationParts(_ path: String) -> (folders: [String], name: String)? {
        if !allowsDestinationSubfolders {
            return Self.filename(path, inside: destination).map { ([], $0) }
        }
        let prefix = destination.path + "/"
        guard path.hasPrefix(prefix), path.utf8.count < PATH_MAX else { return nil }
        let parts = path.dropFirst(prefix.count).components(separatedBy: "/")
        guard parts.count > 1, let name = parts.last, !name.isEmpty, name != ".", name != "..", !name.utf8.contains(0),
              parts.dropLast().allSatisfy(AutomationSubfolderTemplate.isFolderComponent) else { return nil }
        return (Array(parts.dropLast()), name)
    }

    func usableGeneratedFolder(_ folder: URL, env: ScanEnvironment) -> Bool {
        guard folder.path.utf8.count < PATH_MAX,
              let parts = PlanAssembler.components(of: folder.path, under: destination.path) else { return false }
        var ancestor = destination.url
        for part in parts {
            ancestor.appendPathComponent(part, isDirectory: true)
            if SafetyGuard.isPackage(ancestor) || FolderPlanner.liveIsUbiquitous(ancestor) { return false }
        }
        return DestinationGuard.check(folder, env: env, cloudRoots: [], isUbiquitous: FolderPlanner.liveIsUbiquitous,
                                      deviceOf: { FileIdentity(path: $0.path)?.dev }, pickedFolder: source.url) == .usable
    }

    /// Returns a caller-owned descriptor reached through the approved base, with no followed links.
    static func openSubfolders(_ parts: [String], below base: Int32, create: Bool) -> Int32 {
        var root = stat()
        guard fstat(base, &root) == 0 else { return -1 }
        var fd = dup(base)
        guard fd >= 0 else { return -1 }
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        for part in parts {
            var next = openat(fd, part, flags)
            if next < 0, create, errno == ENOENT {
                if mkdirat(fd, part, 0o755) == 0 || errno == EEXIST { next = openat(fd, part, flags) }
            }
            if next < 0 {
                let code = errno
                close(fd)
                errno = code
                return -1
            }
            close(fd)
            fd = next
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_dev == root.st_dev, info.st_uid == getuid(),
                  info.st_flags & UInt32(SF_DATALESS | UF_HIDDEN) == 0 else {
                close(fd)
                errno = EPERM
                return -1
            }
        }
        return fd
    }

    func sourceBoundaryIsCurrent() -> Bool {
        guard let sourceBoundary else { return true }
        guard source.path.hasPrefix(sourceBoundary.path + "/"), let fd = sourceBoundary.openCurrent() else { return false }
        close(fd)
        return true
    }

    func nestedSourceIsUsable(env: ScanEnvironment?) -> Bool {
        guard let sourceBoundary else { return true }
        guard let env, !OrganizeGuard.holdsAppDatabase(sourceBoundary.path) else { return false }
        return DestinationGuard.check(source.url, env: env, cloudRoots: [],
                                      isUbiquitous: FolderPlanner.liveIsUbiquitous,
                                      deviceOf: { FileIdentity(path: $0.path)?.dev },
                                      pickedFolder: sourceBoundary.url) == .usable
    }

    func openSource() -> Int32? {
        guard let sourceBoundary else { return source.openCurrent() }
        let prefix = sourceBoundary.path + "/"
        guard source.path.hasPrefix(prefix), let base = sourceBoundary.openCurrent() else { return nil }
        defer { close(base) }
        let parts = source.path.dropFirst(prefix.count).components(separatedBy: "/")
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.utf8.contains(0) }) else { return nil }
        let fd = Self.openSubfolders(parts, below: base, create: false)
        guard fd >= 0 else { return nil }
        guard source.matchesOpenedFolder(fd) else { close(fd); return nil }
        return fd
    }

    func openDestination(_ folders: [String], create: Bool = false) -> Int32? {
        guard let base = source == destination ? openSource() : destination.openCurrent() else { return nil }
        if folders.isEmpty { return base }
        defer { close(base) }
        let fd = Self.openSubfolders(folders, below: base, create: create)
        return fd >= 0 ? fd : nil
    }

    func location(original: String, moved: String, fileID: UInt64) -> ItemLocation {
        guard let sourceName = Self.filename(original, inside: source),
              let target = destinationParts(moved) else { return .elsewhere }
        func contains(_ fd: Int32?, name: String) -> Bool {
            guard let fd else { return false }
            defer { close(fd) }
            var info = stat()
            return fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0
                && info.st_mode & S_IFMT == S_IFREG && UInt64(info.st_ino) == fileID
        }
        if contains(openDestination(target.folders), name: target.name) { return .atDestination }
        return contains(openSource(), name: sourceName) ? .atOriginal : .elsewhere
    }

    static func date(_ time: timespec) -> Date {
        Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1e9)
    }

    /// Anchors both sides of the rename in the directories that were approved and journaled.
    func move(
        from: String, to: String, fileID: UInt64, snapshot: ItemSnapshot? = nil, undo: Bool = false,
        env: ScanEnvironment? = nil
    ) -> Outcome {
        guard let sourceName = Self.filename(undo ? to : from, inside: source),
              let target = destinationParts(undo ? from : to),
              let oldFD = undo ? openDestination(target.folders) : openSource()
        else { return .skipped(.changedSinceScan) }
        defer { close(oldFD) }
        let oldName = undo ? target.name : sourceName
        let newName = undo ? sourceName : target.name
        var info = stat()
        guard fstatat(oldFD, oldName, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_mode & S_IFMT == S_IFREG, UInt64(info.st_ino) == fileID,
              info.st_uid == getuid(), info.st_flags & UInt32(SF_DATALESS) == 0
        else { return .skipped(undo ? .notWhereWeLeftIt : .changedSinceScan) }
        if let snapshot, snapshot.identitySize != info.st_size
            || snapshot.modified != Self.date(info.st_mtimespec)
            || snapshot.changed != Self.date(info.st_ctimespec) {
            return .skipped(.changedSinceScan)
        }
        if !undo, !nestedSourceIsUsable(env: env) { return .skipped(.safetyViolation) }
        if !undo, !target.folders.isEmpty {
            let folder = URL(fileURLWithPath: to).deletingLastPathComponent()
            guard let env, usableGeneratedFolder(folder, env: env) else { return .skipped(.safetyViolation) }
        }
        guard let newFD = undo ? openSource() : openDestination(target.folders, create: true) else {
            return .skipped(.originalParentMissing)
        }
        defer { close(newFD) }
        if !target.folders.isEmpty {
            let folder = URL(fileURLWithPath: undo ? from : to).deletingLastPathComponent()
            var opened = stat()
            guard fstat(undo ? oldFD : newFD, &opened) == 0,
                  FileIdentity(path: folder.path) == FileIdentity(dev: opened.st_dev, ino: opened.st_ino) else {
                return .skipped(.safetyViolation)
            }
        }
        if sourceBoundary != nil {
            guard sourceBoundaryIsCurrent(), Self.isCurrent(undo ? newFD : oldFD, at: source.path),
                  Self.isCurrent(undo ? oldFD : newFD, at: URL(fileURLWithPath: undo ? from : to).deletingLastPathComponent().path)
            else { return .skipped(.changedSinceScan) }
        }
        if renameatx_np(oldFD, oldName, newFD, newName, UInt32(RENAME_EXCL)) != 0 {
            let code = errno
            if code == EEXIST { return .skipped(undo ? .originalPathOccupied : .destinationOccupied) }
            if code == EXDEV { return .skipped(.crossVolume) }
            return .failed(String(cString: strerror(code)))
        }
        return undo ? .restored : .done
    }
}
