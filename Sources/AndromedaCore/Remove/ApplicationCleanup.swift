import AppKit
import CoreFoundation
import Darwin
import Foundation
import Security

/// A review of one installed application and verified related files in the current user's Library.
public struct ApplicationCleanup: Equatable, Sendable {
    public static let catalogID = "cleanup.application"

    public struct Item: Identifiable, Equatable, Sendable {
        public var id: URL { url }
        public let url: URL
        public let label: String
        public let bytes: Int64
        fileprivate let snapshot: [String: Stamp]
        fileprivate var launchAgent: AssociatedLaunchAgent?
        public fileprivate(set) var mayContainUserScripts = false
    }

    public let app: Item
    public let related: [Item]
    public let relatedOwnershipUnclear: Bool
    fileprivate let bundleID: String
    public var bundleIdentifier: String { bundleID }

    public enum Action: Hashable, Sendable { case uninstall, clearData }

    public enum Architecture: String, Sendable {
        case appleSilicon = "Apple silicon"
        case universal = "Universal"
        case intel = "Intel only"
        case legacy = "Legacy"
    }

    public struct SigningTeam: Equatable, Sendable {
        public let id: String
        public let certificateName: String?

        public var displayName: String { certificateName ?? id }
    }

    /// Display metadata from the installed signature. Trash checks use their own identity evidence.
    public static func signingTeam(of url: URL, env: ScanEnvironment) -> SigningTeam? {
        guard isApplicationPath(url, env: env),
              let plist = try? readBundleInfo(url),
              let executable = mainExecutable(in: url, plist: plist) else { return nil }
        let path = SafetyGuard.withoutSystemPathAlias(executable.standardizedFileURL.path)
        let fd = open(path, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_flags & UInt32(SF_DATALESS) == 0 else { return nil }

        var code: SecStaticCode?
        var signing: CFDictionary?
        guard SecStaticCodeCreateWithPath(url.standardizedFileURL as CFURL, [], &code) == errSecSuccess,
              let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &signing) == errSecSuccess,
              let metadata = signing as? [String: Any],
              let team = metadata[kSecCodeInfoTeamIdentifier as String] as? String,
              team.wholeMatch(of: /[A-Z0-9]{10}/) != nil,
              FileIdentity(path: path) == FileIdentity(dev: info.st_dev, ino: info.st_ino) else { return nil }
        let certificate = (metadata[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first
        let summary = certificate.flatMap { SecCertificateCopySubjectSummary($0) as String? }
        let name = summary.flatMap { label -> String? in
            guard !label.isEmpty, label.count <= 200,
                  !label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
            let prefix = "Developer ID Application: "
            let suffix = " (\(team))"
            guard label.hasPrefix(prefix), label.hasSuffix(suffix), label.count > prefix.count + suffix.count else { return label }
            return String(label.dropFirst(prefix.count).dropLast(suffix.count))
        }
        return SigningTeam(id: team, certificateName: name)
    }

    /// Inspects the main executable without launching it.
    public static func architecture(of url: URL, env: ScanEnvironment) -> Architecture? {
        guard isApplicationPath(url, env: env),
              let plist = try? readBundleInfo(url),
              let executable = mainExecutable(in: url, plist: plist) else { return nil }
        let path = SafetyGuard.withoutSystemPathAlias(executable.standardizedFileURL.path)
        let fd = open(path, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_flags & UInt32(SF_DATALESS) == 0 else { return nil }

        // Have Core Foundation inspect the opened file, even if the original path is replaced.
        let openedURL = URL(fileURLWithPath: "/dev/fd/\(fd)")
        guard let values = CFBundleCopyExecutableArchitecturesForURL(openedURL as CFURL) as? [NSNumber],
              !values.isEmpty, FileIdentity(path: path) == FileIdentity(dev: info.st_dev, ino: info.st_ino) else { return nil }
        let cpus = Set(values.map(\.int32Value))
        let silicon = cpus.contains(CPU_TYPE_ARM64)
        let intel = cpus.contains(CPU_TYPE_X86_64)
        if silicon { return intel ? .universal : .appleSilicon }
        let legacy: Set<Int32> = [CPU_TYPE_I386, CPU_TYPE_POWERPC, CPU_TYPE_POWERPC64]
        if intel, cpus.subtracting(legacy) == [CPU_TYPE_X86_64] { return .intel }
        return cpus.isSubset(of: legacy) ? .legacy : nil
    }

    private static func mainExecutable(in url: URL, plist: [String: Any]) -> URL? {
        guard let name = plist["CFBundleExecutable"] as? String,
              !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else { return nil }
        return url.appendingPathComponent("Contents/MacOS", isDirectory: true).appendingPathComponent(name)
    }

    public func relatedItems(for action: Action) -> [Item] {
        action == .uninstall ? related : related.filter { $0.launchAgent == nil }
    }

    public struct ObservedApplication: Codable, Equatable, Identifiable, Sendable {
        public let bundleID: String
        public let name: String
        public var id: String { bundleID.lowercased() }
        fileprivate let launchAgentOnly: Bool?
        public var isLaunchAgentOnly: Bool { launchAgentOnly == true }

        init(bundleID: String, name: String, launchAgentOnly: Bool = false) {
            self.bundleID = bundleID
            self.name = name
            self.launchAgentOnly = launchAgentOnly ? true : nil
        }
    }

    public struct Leftovers: Equatable, Sendable {
        public let application: ObservedApplication
        public let items: [Item]

        func removals(selected: Set<URL>) -> [PlannedRemoval]? {
            guard !selected.isEmpty, selected.isSubset(of: Set(items.map(\.url))) else { return nil }
            return items.filter { selected.contains($0.url) }.map {
                TrashCheck(item: $0, bundleID: application.bundleID, role: .leftover).removal
            }
        }
    }

    /// Records positive observations only. A partial or cancelled scan is never evidence of absence.
    public static func observe(_ apps: [AppItem], env: ScanEnvironment, control: ScanControl?) -> [ObservedApplication] {
        observeWithPaths(apps, env: env, control: control).map(\.application)
    }

    public static func observeWithPaths(
        _ apps: [AppItem], env: ScanEnvironment, control: ScanControl?
    ) -> [(url: URL, application: ObservedApplication)] {
        apps.compactMap { app in
            guard control?.isCancelled != true, isApplicationPath(app.url, env: env),
                  SafetyGuard.checkRemovable(app.url, env: env) == nil,
                  let id = try? readBundleID(app.url), isSupported(id) else { return nil }
            return (app.url, ObservedApplication(bundleID: id, name: app.url.deletingPathExtension().lastPathComponent))
        }
    }

    /// A bundle still in this user's Trash is positive evidence even on the first scan.
    /// Call only after Full Disk Access has been confirmed.
    public static func observeTrashedApplications(env: ScanEnvironment) -> [ObservedApplication] {
        let path = SafetyGuard.withoutSystemPathAlias(env.trash.standardizedFileURL.path)
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(),
              let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return [] }
        let identity = FileIdentity(dev: info.st_dev, ino: info.st_ino)
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let observed: [ObservedApplication] = names.sorted().compactMap { name in
            let url = folder.appendingPathComponent(name)
            guard url.pathExtension.lowercased() == "app", let id = try? readBundleID(url), isSupported(id) else { return nil }
            return ObservedApplication(bundleID: id, name: url.deletingPathExtension().lastPathComponent)
        }
        return FileIdentity(path: path) == identity ? observed : []
    }

    /// App Store records can identify apps removed before Andromeda first scanned this Mac.
    public static func observeAppStoreHistory(env: ScanEnvironment) -> [ObservedApplication] {
        let history = env.root.appendingPathComponent("Library/Receipts/InstallHistory.plist")
        let path = SafetyGuard.withoutSystemPathAlias(history.standardizedFileURL.path)
        var root = stat()
        guard lstat(env.root.path, &root) == 0, root.st_mode & S_IFMT == S_IFDIR else { return [] }
        let fd = open(path, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return [] }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == root.st_uid,
              info.st_mode & S_IWOTH == 0, (1...16 * 1024 * 1024).contains(info.st_size),
              let data = try? file.read(upToCount: Int(info.st_size)), data.count == info.st_size,
              let rows = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [Any]
        else { return [] }
        var recent: [String: (Date, ObservedApplication)] = [:]
        for row in rows {
            guard let entry = row as? [String: Any], entry["processName"] as? String == "appstoreagent",
                  let ids = entry["packageIdentifiers"] as? [String], ids.count == 1, let id = ids.first,
                  isSupported(id), let date = entry["date"] as? Date else { continue }
            let label = (entry["displayName"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let useLabel = !label.isEmpty && label.count <= 200
                && !label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            let app = ObservedApplication(bundleID: id, name: useLabel ? label : id)
            if recent[app.id].map({ $0.0 <= date }) ?? true { recent[app.id] = (date, app) }
        }
        return recent.values.map { $0.1 }
    }

    /// Recover app identity from this user's macOS crash reports without opening the reported path.
    public static func observeCrashReports(env: ScanEnvironment) -> [ObservedApplication] {
        latestCrashApplications(crashReports(env: env))
    }

    private struct AppCrashReport {
        let url: URL
        let application: ObservedApplication
        let stamp: Stamp
    }

    private static func latestCrashApplications(_ reports: [AppCrashReport]) -> [ObservedApplication] {
        var recent: [String: AppCrashReport] = [:]
        for report in reports {
            let id = report.application.id
            let modified = (report.stamp.modifiedSeconds, report.stamp.modifiedNanos)
            if recent[id].map({ ($0.stamp.modifiedSeconds, $0.stamp.modifiedNanos) <= modified }) ?? true {
                recent[id] = report
            }
        }
        return recent.values.map(\.application)
    }

    private static func crashReports(env: ScanEnvironment) -> [AppCrashReport] {
        let folder = env.home.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        let path = SafetyGuard.withoutSystemPathAlias(folder.standardizedFileURL.path)
        let directory = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard directory >= 0 else { return [] }
        defer { close(directory) }
        var info = stat()
        guard fstat(directory, &info) == 0, info.st_uid == getuid(), info.st_mode & (S_IWGRP | S_IWOTH) == 0,
              info.st_dev == FileIdentity(path: env.home.path)?.dev,
              let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return [] }
        let identity = FileIdentity(dev: info.st_dev, ino: info.st_ino)
        let decoder = JSONDecoder()
        let reportNames = names.sorted().lazy.filter { !$0.hasPrefix(".") && $0.hasSuffix(".ips") }
        var reports: [AppCrashReport] = []
        var remainingBytes = 32 * 1024 * 1024
        for filename in reportNames.prefix(256) {
            let fd = openat(directory, filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { continue }
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
                  info.st_dev == identity.dev, info.st_flags & UInt32(SF_DATALESS) == 0,
                  info.st_mode & (S_IWGRP | S_IWOTH) == 0, (1...2 * 1024 * 1024).contains(info.st_size),
                  info.st_size <= remainingBytes else { continue }
            let stamp = Stamp(info)
            remainingBytes -= Int(info.st_size)
            guard let data = try? file.read(upToCount: Int(info.st_size)), data.count == info.st_size,
                  fstat(fd, &info) == 0, Stamp(info) == stamp,
                  let newline = data.firstIndex(of: 10),
                  let header = try? decoder.decode(CrashHeader.self, from: data[..<newline]),
                  header.bug_type == "309", isSupported(header.bundleID),
                  let crash = try? decoder.decode(CrashBody.self, from: data[data.index(after: newline)...]),
                  crash.bundleInfo.CFBundleIdentifier == header.bundleID,
                  let name = crashApplicationName(executable: crash.procPath, env: env) else { continue }
            reports.append(AppCrashReport(url: folder.appendingPathComponent(filename),
                                          application: ObservedApplication(bundleID: header.bundleID, name: name), stamp: stamp))
        }
        return FileIdentity(path: path) == identity ? reports : []
    }

    private struct CrashHeader: Decodable {
        let bug_type: String
        let bundleID: String
    }

    private struct CrashBody: Decodable {
        struct BundleInfo: Decodable { let CFBundleIdentifier: String }
        let procPath: String
        let bundleInfo: BundleInfo
    }

    private static func crashApplicationName(executable: String, env: ScanEnvironment) -> String? {
        guard executable.hasPrefix("/"), !executable.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !executable.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        let macOS = URL(fileURLWithPath: executable).deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents",
              app.pathExtension.lowercased() == "app" else { return nil }
        let path = SafetyGuard.withoutSystemPathAlias(app.standardizedFileURL.path)
        let dataRoot = SafetyGuard.withoutSystemPathAlias(env.dataVolumeRoot.standardizedFileURL.path)
        let startupPath = dataRoot != "/" && path.hasPrefix(dataRoot + "/")
            ? String(path.dropFirst(dataRoot.count)) : path
        guard isApplicationPath(app, env: env)
                || isApplicationPath(URL(fileURLWithPath: startupPath, isDirectory: true), env: env) else { return nil }
        return app.deletingPathExtension().lastPathComponent
    }

    fileprivate struct AssociatedLaunchAgent: Equatable, Sendable {
        let url: URL
        let bundleID: String
        let appURL: URL
        let executable: URL
        let stamp: Stamp

        var app: ObservedApplication {
            ObservedApplication(bundleID: bundleID, name: appURL.deletingPathExtension().lastPathComponent,
                                launchAgentOnly: true)
        }
    }

    private static func launchAgentsDirectory(_ env: ScanEnvironment) -> URL {
        let url = env.home.appendingPathComponent("Library/LaunchAgents", isDirectory: true).standardizedFileURL
        return URL(fileURLWithPath: SafetyGuard.withoutSystemPathAlias(url.path), isDirectory: true)
    }

    private static func openLaunchAgents(_ url: URL, env: ScanEnvironment) -> (Int32, FileIdentity)? {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & (S_IWGRP | S_IWOTH) == 0,
              info.st_dev == FileIdentity(path: env.home.path)?.dev else { close(fd); return nil }
        return (fd, FileIdentity(dev: info.st_dev, ino: info.st_ino))
    }

    private static func orphanedLaunchAgents(env: ScanEnvironment) -> [AssociatedLaunchAgent] {
        associatedLaunchAgents(env: env).filter { bundleIsMissing($0.appURL, env: env) }
    }

    private static func associatedLaunchAgents(env: ScanEnvironment) -> [AssociatedLaunchAgent] {
        let folder = launchAgentsDirectory(env)
        guard let (fd, identity) = openLaunchAgents(folder, env: env) else { return [] }
        defer { close(fd) }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        var budget = 8 * 1024 * 1024
        var results: [AssociatedLaunchAgent] = []
        for name in names.sorted().lazy.filter({ !$0.hasPrefix(".") && $0.hasSuffix(".plist") }).prefix(512) {
            if let agent = associatedLaunchAgent(named: name, in: folder, fd: fd, env: env, budget: &budget) {
                results.append(agent)
            }
        }
        return FileIdentity(path: folder.path) == identity ? results : []
    }

    private static func associatedLaunchAgent(at url: URL, env: ScanEnvironment) -> AssociatedLaunchAgent? {
        let folder = launchAgentsDirectory(env)
        guard url.deletingLastPathComponent().path == folder.path,
              let (fd, identity) = openLaunchAgents(folder, env: env) else { return nil }
        defer { close(fd) }
        var budget = 128 * 1024
        let agent = associatedLaunchAgent(named: url.lastPathComponent, in: folder, fd: fd, env: env, budget: &budget)
        return FileIdentity(path: folder.path) == identity ? agent : nil
    }

    private static func associatedLaunchAgent(
        named name: String, in folder: URL, fd: Int32, env: ScanEnvironment, budget: inout Int
    ) -> AssociatedLaunchAgent? {
        guard budget > 0, !name.hasPrefix("."), name.hasSuffix(".plist") else { return nil }
        let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, info.st_mode & (S_IWGRP | S_IWOTH) == 0, info.st_flags & UInt32(SF_DATALESS) == 0,
              (1...128 * 1024).contains(info.st_size), info.st_size <= budget else { return nil }
        let stamp = Stamp(info)
        budget -= Int(info.st_size)
        guard let data = try? handle.read(upToCount: Int(info.st_size)), data.count == info.st_size,
              fstat(file, &info) == 0, Stamp(info) == stamp,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let label = plist["Label"] as? String, !label.isEmpty, !label.lowercased().hasPrefix("com.apple."),
              plist["RootDirectory"] == nil, plist["BundleProgram"] == nil, (plist["EnableGlobbing"] as? Bool) != true
        else { return nil }
        let declared = plist["AssociatedBundleIdentifiers"]
        let associated = declared as? [String] ?? (declared as? String).map { [$0] } ?? []
        let program = plist["Program"] == nil
            ? (plist["ProgramArguments"] as? [String])?.first
            : plist["Program"] as? String
        guard associated.count == 1, let id = associated.first, isSupported(id),
              let program, let (app, executable) = launchAgentProgram(program, env: env) else { return nil }
        return AssociatedLaunchAgent(url: folder.appendingPathComponent(name), bundleID: id,
                                     appURL: app, executable: executable, stamp: stamp)
    }

    private static func launchAgentProgram(_ executable: String, env: ScanEnvironment) -> (URL, URL)? {
        guard executable.hasPrefix("/"), !executable.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !executable.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        let path = SafetyGuard.withoutSystemPathAlias(URL(fileURLWithPath: executable).standardizedFileURL.path)
        for root in env.applicationsRoots {
            let parent = SafetyGuard.withoutSystemPathAlias(root.standardizedFileURL.path)
            let prefix = parent + "/"
            guard path.hasPrefix(prefix) else { continue }
            let parts = path.dropFirst(prefix.count).split(separator: "/")
            guard let bundle = parts.firstIndex(where: { $0.lowercased().hasSuffix(".app") }),
                  parts.count >= bundle + 4, parts[bundle + 1] == "Contents" else { continue }
            let app = root.appendingPathComponent(parts.prefix(bundle + 1).joined(separator: "/"), isDirectory: true)
            guard isApplicationPath(app, env: env), SafetyGuard.checkRemovable(app, env: env) == nil else { continue }
            return (URL(fileURLWithPath: SafetyGuard.withoutSystemPathAlias(app.standardizedFileURL.path), isDirectory: true),
                    URL(fileURLWithPath: path))
        }
        return nil
    }

    private static func bundleIsMissing(_ app: URL, env: ScanEnvironment) -> Bool {
        let path = app.path
        guard path.utf8.count < Int(PATH_MAX), let home = FileIdentity(path: env.home.path),
              var ancestor = env.applicationsRoots.lazy.map({
                  SafetyGuard.withoutSystemPathAlias($0.standardizedFileURL.path)
              }).first(where: { path.hasPrefix($0 + "/") }) else { return false }
        let components = path.dropFirst(ancestor.count + 1).split(separator: "/")
        let directoryFlags = O_RDONLY | O_DIRECTORY | O_CLOEXEC
        var fd = open(ancestor, directoryFlags | O_NOFOLLOW_ANY)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        for (index, component) in components.enumerated() {
            let name = String(component)
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_dev == home.dev else { return false }
            let identity = FileIdentity(dev: info.st_dev, ino: info.st_ino)
            if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                guard errno == ENOENT else { return false }
                // Reopen the last existing ancestor to reject a renamed or substituted path.
                let current = open(ancestor, directoryFlags | O_NOFOLLOW_ANY)
                guard current >= 0 else { return false }
                defer { close(current) }
                return fstat(current, &info) == 0 && FileIdentity(dev: info.st_dev, ino: info.st_ino) == identity
                    && fstatat(current, name, &info, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT
                    && FileIdentity(path: ancestor) == identity
            }
            guard index < components.count - 1, info.st_mode & S_IFMT == S_IFDIR else { return false }
            let next = openat(fd, name, directoryFlags | O_NOFOLLOW)
            guard next >= 0 else { return false }
            let entry = FileIdentity(dev: info.st_dev, ino: info.st_ino)
            close(fd)
            fd = next
            guard fstat(fd, &info) == 0, FileIdentity(dev: info.st_dev, ino: info.st_ino) == entry else { return false }
            ancestor += "/" + name
        }
        return false
    }

    private static func executableIsPresent(_ agent: AssociatedLaunchAgent) -> Bool {
        let fd = open(agent.executable.path, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var info = stat()
        return fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
            && info.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0 && info.st_flags & UInt32(SF_DATALESS) == 0
            && info.st_dev == FileIdentity(path: agent.appURL.path)?.dev
    }

    private static func launchAgentItem(_ agent: AssociatedLaunchAgent, label: String, env: ScanEnvironment) -> Item? {
        guard var item = inspectItem(agent.url, label: label, env: env, isApp: false),
              item.snapshot[""] == agent.stamp else { return nil }
        item.launchAgent = agent
        return item
    }

    /// Identifies candidates without walking the contents of their Library folders.
    public static func leftoverCandidates(
        _ known: [ObservedApplication], env: ScanEnvironment, includeContainers: Bool,
        ignoringPaths: [String: Set<String>] = [:]
    ) -> [ObservedApplication]? {
        let agents = orphanedLaunchAgents(env: env).filter { agent in
            ignoringPaths[agent.app.id]?.contains(SafetyGuard.withoutSystemPathAlias(agent.url.path)) != true
        }
        let agentsByID = Dictionary(grouping: agents) { $0.app.id }
        let reports = crashReports(env: env)
        let reportsByID = Dictionary(grouping: reports) { $0.application.bundleID }
        let knownIDs = Set(known.map(\.id))
        let observed = known + latestCrashApplications(reports).filter { !knownIDs.contains($0.id) }
        let observedIDs = Set(observed.map(\.id))
        let candidates = observed + agentsByID.compactMap { id, entries in
            observedIDs.contains(id) ? nil : entries.first?.app
        }
        guard !candidates.isEmpty else { return [] }
        guard let installed = installedApplications(env: env) else { return nil }
        let installedIDs = Set(installed.map { $0.id.lowercased() })
        let hostPreferences = hostPreferencesByBundleID(env: env)
        return candidates.filter { app in
            guard isSupported(app.bundleID), !installedIDs.contains(app.id) else { return false }
            let hasReports = reportsByID[app.bundleID, default: []].contains { report in
                ignoringPaths[app.id]?.contains(SafetyGuard.withoutSystemPathAlias(report.url.path)) != true
            }
            let hasFiles = agentsByID[app.id] != nil || hasReports || (app.launchAgentOnly != true && relatedLocations(
                app.bundleID, env: env, includeContainers: includeContainers, hostPreferences: hostPreferences,
                includeUserScripts: true
            ).contains { location in
                let path = SafetyGuard.withoutSystemPathAlias(location.url.path)
                guard ignoringPaths[app.id]?.contains(path) != true else { return false }
                let fd = open(path, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
                guard fd >= 0 else { return false }
                defer { close(fd) }
                var info = stat()
                return fstat(fd, &info) == 0 && info.st_uid == getuid() && location.accepts(info.st_mode)
            })
            return hasFiles && !hasRegisteredCopyElsewhere(app.bundleID, env: env)
        }
        .sorted {
            let byName = $0.name.localizedStandardCompare($1.name)
            return byName == .orderedSame ? $0.id < $1.id : byName == .orderedAscending
        }
    }

    public static func inspectLeftovers(
        _ app: ObservedApplication, env: ScanEnvironment, includeContainers: Bool, ignoringPaths: Set<String> = []
    ) -> Leftovers? {
        inspectLeftovers([app], env: env, includeContainers: includeContainers, ignoringPaths: [app.id: ignoringPaths]).first
    }

    public static func inspectLeftovers(
        _ apps: [ObservedApplication], env: ScanEnvironment, includeContainers: Bool,
        ignoringPaths: [String: Set<String>]
    ) -> [Leftovers] {
        guard !apps.isEmpty, let installed = installedApplications(env: env) else { return [] }
        let installedIDs = Set(installed.map { $0.id.lowercased() })
        let hostPreferences = hostPreferencesByBundleID(env: env)
        let reports = Dictionary(grouping: crashReports(env: env)) { $0.application.bundleID }
        let agents = Dictionary(grouping: orphanedLaunchAgents(env: env)) { $0.app.id }
        return apps.compactMap { app in
            guard isSupported(app.bundleID), !installedIDs.contains(app.id),
                  !hasRegisteredCopyElsewhere(app.bundleID, env: env) else { return nil }
            return inspectLeftoverItems(app, env: env, includeContainers: includeContainers,
                                        hostPreferences: hostPreferences, reports: reports[app.bundleID, default: []],
                                        agents: agents[app.id, default: []], ignoringPaths: ignoringPaths[app.id, default: []])
        }
    }

    private static func inspectLeftoverItems(
        _ app: ObservedApplication, env: ScanEnvironment, includeContainers: Bool,
        hostPreferences: [String: [URL]], reports: [AppCrashReport], agents: [AssociatedLaunchAgent],
        ignoringPaths: Set<String>
    ) -> Leftovers? {
        var items = app.launchAgentOnly == true ? [] : inspectRelated(app.bundleID, env: env, includeContainers: includeContainers,
                                                                     hostPreferences: hostPreferences,
                                                                     includeUserScripts: true,
                                                                     ignoringPaths: ignoringPaths)
        items += crashReportItems(reports, env: env, ignoringPaths: ignoringPaths)
        for agent in agents {
            guard !ignoringPaths.contains(SafetyGuard.withoutSystemPathAlias(agent.url.path)),
                  let item = launchAgentItem(agent, label: "Orphaned LaunchAgent", env: env) else { continue }
            items.append(item)
        }
        return items.isEmpty ? nil : Leftovers(application: app, items: items)
    }

    public static func isApplicationPath(_ url: URL, env: ScanEnvironment) -> Bool {
        guard url.isFileURL, url.pathExtension.lowercased() == "app" else { return false }
        let path = SafetyGuard.withoutSystemPathAlias(url.standardizedFileURL.path)
        return env.applicationsRoots.contains { root in
            let prefix = SafetyGuard.withoutSystemPathAlias(root.standardizedFileURL.path) + "/"
            guard path.hasPrefix(prefix) else { return false }
            let components = path.dropFirst(prefix.count).split(separator: "/")
            if components.count == 1 { return true }
            return !components.contains(where: { $0.hasPrefix(".") })
                && !components.dropLast().contains(where: { $0.lowercased().hasSuffix(".app") })
        }
    }

    public static func inspect(_ url: URL, env: ScanEnvironment, includeContainers: Bool) -> Self? {
        inspect(url, env: env, includeContainers: includeContainers, copies: { installedCopies(of: $0, env: env) },
                agents: { path in associatedLaunchAgents(env: env).filter { $0.appURL.path == path } },
                reports: { id in crashReports(env: env).filter { $0.application.bundleID == id } },
                hostPreferences: hostPreferencesByBundleID(env: env))
    }

    /// Use one inventory for ownership checks across a batch. Execution still checks current ownership.
    public static func inspectApplications(_ urls: [URL], env: ScanEnvironment, includeContainers: Bool) -> [Self] {
        let installed = installedApplications(env: env).map { Dictionary(grouping: $0, by: { $0.id.lowercased() }) }
        let agentsByPath = Dictionary(grouping: associatedLaunchAgents(env: env)) { $0.appURL.path }
        let reportsByID = Dictionary(grouping: crashReports(env: env)) { $0.application.bundleID }
        let hostPreferences = hostPreferencesByBundleID(env: env)
        return urls.compactMap { url in
            inspect(url, env: env, includeContainers: includeContainers, copies: { installed?[$0.lowercased()]?.map(\.url) },
                    agents: { agentsByPath[$0, default: []] }, reports: { reportsByID[$0, default: []] },
                    hostPreferences: hostPreferences)
        }
    }

    private static func inspect(
        _ url: URL, env: ScanEnvironment, includeContainers: Bool, copies: (String) -> [URL]?,
        agents: (String) -> [AssociatedLaunchAgent], reports: (String) -> [AppCrashReport],
        hostPreferences: [String: [URL]]
    ) -> Self? {
        let url = url.standardizedFileURL
        guard isApplicationPath(url, env: env), let bundleID = try? readBundleID(url),
              isSupported(bundleID), let app = inspectItem(url, label: "Application", env: env, isApp: true)
        else { return nil }
        let unique = copies(bundleID)?.map {
            SafetyGuard.withoutSystemPathAlias($0.path)
        } == [SafetyGuard.withoutSystemPathAlias(url.path)] && !hasRegisteredCopyElsewhere(bundleID, env: env)
        var related = unique ? inspectRelated(bundleID, env: env, includeContainers: includeContainers,
                                              hostPreferences: hostPreferences) : []
        if unique {
            related += crashReportItems(reports(bundleID), env: env)
            let path = SafetyGuard.withoutSystemPathAlias(url.path)
            related += agents(path).compactMap { agent in
                guard agent.bundleID == bundleID, executableIsPresent(agent),
                      let executable = app.snapshot[String(agent.executable.path.dropFirst(path.count + 1))],
                      FileIdentity(path: agent.executable.path) == executable.identity else { return nil }
                return launchAgentItem(agent, label: "App LaunchAgent", env: env)
            }
        }
        return Self(app: app, related: related, relatedOwnershipUnclear: !unique, bundleID: bundleID)
    }

    private static func crashReportItems(
        _ reports: [AppCrashReport], env: ScanEnvironment, ignoringPaths: Set<String> = []
    ) -> [Item] {
        reports.compactMap { report in
            guard !ignoringPaths.contains(SafetyGuard.withoutSystemPathAlias(report.url.path)),
                  let item = inspectItem(report.url, label: "Crash report", env: env, isApp: false, expectedType: S_IFREG),
                  item.snapshot[""] == report.stamp else { return nil }
            return item
        }
    }

    private static func inspectRelated(
        _ bundleID: String, env: ScanEnvironment, includeContainers: Bool, hostPreferences: [String: [URL]],
        includeUserScripts: Bool = false,
        ignoringPaths: Set<String> = []
    ) -> [Item] {
        relatedLocations(bundleID, env: env, includeContainers: includeContainers,
                         hostPreferences: hostPreferences, includeUserScripts: includeUserScripts).compactMap { location in
            guard !ignoringPaths.contains(SafetyGuard.withoutSystemPathAlias(location.url.path)) else { return nil }
            guard var item = inspectItem(location.url, label: location.label, env: env, isApp: false,
                                         expectedType: location.type) else { return nil }
            item.mayContainUserScripts = location.mayContainUserScripts
            return item
        }
    }

    private struct RelatedLocation {
        let url: URL
        let label: String
        let type: mode_t?
        var mayContainUserScripts = false

        func accepts(_ mode: mode_t) -> Bool {
            let kind = mode & S_IFMT
            if let type { return kind == type }
            return kind == S_IFREG || kind == S_IFDIR
        }
    }

    private static func relatedLocations(
        _ bundleID: String, env: ScanEnvironment, includeContainers: Bool, hostPreferences: [String: [URL]],
        includeUserScripts: Bool
    ) -> [RelatedLocation] {
        let library = env.home.appendingPathComponent("Library", isDirectory: true)
        let locations = [
            ("Caches/\(bundleID)", "Caches"),
            ("Logs/\(bundleID)", "Logs"),
            ("Preferences/\(bundleID).plist", "Preferences"),
            ("Saved Application State/\(bundleID).savedState", "Saved window state"),
            ("Application Support/\(bundleID)", "Application Support"),
        ] + (includeContainers ? [("Containers/\(bundleID)", "App container")] : [])
        var typedLocations = [
            RelatedLocation(url: library.appendingPathComponent("HTTPStorages/\(bundleID)"), label: "HTTP storage", type: S_IFDIR),
            RelatedLocation(url: library.appendingPathComponent("HTTPStorages/\(bundleID).binarycookies"), label: "HTTP cookies", type: S_IFREG),
            RelatedLocation(url: library.appendingPathComponent("WebKit/\(bundleID)"), label: "WebKit website data", type: S_IFDIR),
        ]
        if includeUserScripts {
            typedLocations.append(RelatedLocation(
                url: library.appendingPathComponent("Application Scripts/\(bundleID)"),
                label: "User scripts", type: S_IFDIR, mayContainUserScripts: true))
        }
        return locations.map { path, label in RelatedLocation(url: library.appendingPathComponent(path), label: label, type: nil) }
            + typedLocations
            + (hostPreferences[bundleID] ?? []).map { RelatedLocation(url: $0, label: "Per-Mac preferences", type: S_IFREG) }
    }

    private static func hostPreferencesByBundleID(env: ScanEnvironment) -> [String: [URL]] {
        let directory = env.home.appendingPathComponent("Library/Preferences/ByHost", isDirectory: true)
        let path = SafetyGuard.withoutSystemPathAlias(directory.standardizedFileURL.path)
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { return [:] }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(),
              let names = try? FileManager.default.contentsOfDirectory(atPath: path),
              FileIdentity(path: path) == FileIdentity(dev: info.st_dev, ino: info.st_ino) else { return [:] }
        var byBundle: [String: [URL]] = [:]
        for name in names.sorted() where name.hasSuffix(".plist") {
            let stem = name.dropLast(".plist".count)
            guard let separator = stem.lastIndex(of: ".") else { continue }
            let suffix = String(stem[stem.index(after: separator)...])
            guard let uuid = UUID(uuidString: suffix), uuid.uuidString.caseInsensitiveCompare(suffix) == .orderedSame else { continue }
            let bundleID = String(stem[..<separator])
            byBundle[bundleID, default: []].append(directory.appendingPathComponent(name))
        }
        return byBundle
    }

    func removals(selected: Set<URL>, action: Action) -> [PlannedRemoval]? {
        let available = relatedItems(for: action)
        guard selected.isSubset(of: Set(available.map(\.url))) else { return nil }
        let items = available.filter { selected.contains($0.url) }
        switch action {
        case .uninstall:
            let application = TrashCheck(item: app, bundleID: bundleID, role: .application).removal
            return [application] + items.map {
                TrashCheck(item: $0, bundleID: bundleID, role: .related(appURL: app.url)).removal
            }
        case .clearData:
            guard !items.isEmpty, let identity = app.snapshot[""]?.identity else { return nil }
            let role = TrashCheck.Role.appData(appURL: app.url, identity: identity)
            return items.map { TrashCheck(item: $0, bundleID: bundleID, role: role).removal }
        }
    }

    struct TrashCheck: Equatable, Sendable {
        enum Role: Equatable, Sendable {
            case application, leftover
            case related(appURL: URL)
            case appData(appURL: URL, identity: FileIdentity)
        }
        let item: Item
        let bundleID: String
        let role: Role

        var removal: PlannedRemoval {
            PlannedRemoval(catalogEntryID: ApplicationCleanup.catalogID, action: .moveToTrash(item.url),
                           expectedBytes: item.bytes, expectation: nil, appsMustBeQuit: [bundleID],
                           applicationCheck: self)
        }

        func verify(env: ScanEnvironment) -> Bool {
            switch role {
            case .application:
                guard ApplicationCleanup.isApplicationPath(item.url, env: env),
                      (try? ApplicationCleanup.readBundleID(item.url)) == bundleID else { return false }
            case .related, .leftover:
                // A second installed copy may have appeared after review. Its data must stay in place.
                guard ApplicationCleanup.installedCopies(of: bundleID, env: env)?.isEmpty == true,
                      !ApplicationCleanup.hasRegisteredCopyElsewhere(bundleID, env: env) else { return false }
                if let agent = item.launchAgent {
                    if case .related(let appURL) = role,
                       SafetyGuard.withoutSystemPathAlias(appURL.path) != agent.appURL.path { return false }
                    guard ApplicationCleanup.associatedLaunchAgent(at: item.url, env: env) == agent,
                          ApplicationCleanup.bundleIsMissing(agent.appURL, env: env) else {
                        return false
                    }
                }
            case .appData(let appURL, let identity):
                let path = SafetyGuard.withoutSystemPathAlias(appURL.path)
                guard item.launchAgent == nil, ApplicationCleanup.installedCopies(of: bundleID, env: env)?.map({
                    SafetyGuard.withoutSystemPathAlias($0.path)
                }) == [path], FileIdentity(path: path) == identity,
                    !ApplicationCleanup.hasRegisteredCopyElsewhere(bundleID, env: env) else { return false }
            }
            return ApplicationCleanup.snapshot(item.url, env: env, isApp: role == .application) == item.snapshot
        }
    }

    private static func isSupported(_ id: String) -> Bool {
        let key = id.lowercased()
        return id.wholeMatch(of: /[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+/) != nil
            && key != "com.apple" && !key.hasPrefix("com.apple.")
            && !key.hasPrefix("io.github.jyannni.diskplain")
    }

    private static func readBundleID(_ url: URL) throws -> String? {
        guard let id = try readBundleInfo(url)?["CFBundleIdentifier"] as? String,
              id.wholeMatch(of: /[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+/) != nil else { return nil }
        return id
    }

    private static func readBundleInfo(_ url: URL) throws -> [String: Any]? {
        let path = url.appendingPathComponent("Contents/Info.plist").path
        let fd = open(SafetyGuard.withoutSystemPathAlias(path), O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            let code = errno
            if code == ENOENT || code == ENOTDIR { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, (1...2_000_000).contains(info.st_size),
              let data = try handle.read(upToCount: Int(info.st_size)) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    private static func installedCopies(of id: String, env: ScanEnvironment) -> [URL]? {
        installedApplications(env: env)?.compactMap { $0.id.caseInsensitiveCompare(id) == .orderedSame ? $0.url : nil }
    }

    private static func hasRegisteredCopyElsewhere(_ id: String, env: ScanEnvironment) -> Bool {
        containsAppOutsideInventory(NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id), env: env)
    }

    static func containsAppOutsideInventory(_ urls: [URL], env: ScanEnvironment) -> Bool {
        let dataRoot = env.dataVolumeRoot.standardizedFileURL.path
        func normalized(_ url: URL) -> String {
            let path = url.standardizedFileURL.path
            // Launch Services can return the Data-volume spelling of a startup-disk path.
            let startupPath = dataRoot != "/" && path.hasPrefix(dataRoot + "/") ? String(path.dropFirst(dataRoot.count)) : path
            return SafetyGuard.withoutSystemPathAlias(startupPath)
        }
        let covered = (env.applicationsRoots + [env.trash]).map(normalized)
        return urls.contains { url in
            guard url.isFileURL else { return false }
            let path = normalized(url)
            return !covered.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
    }

    private static func installedApplications(env: ScanEnvironment) -> [(url: URL, id: String)]? {
        var apps: [(url: URL, id: String)] = []
        for root in env.applicationsRoots.map(\.standardizedFileURL) {
            var info = stat()
            if lstat(root.path, &info) != 0, errno == ENOENT { continue }
            let fd = open(SafetyGuard.withoutSystemPathAlias(root.path), O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            guard fd >= 0 else { return nil }
            close(fd)
            var incomplete = false
            guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                               options: [.skipsPackageDescendants], errorHandler: { _, _ in
                incomplete = true
                return false
            }) else { return nil }
            for case let entry as URL in entries where entry.pathExtension.lowercased() == "app" {
                entries.skipDescendants()
                var info = stat()
                guard lstat(entry.path, &info) == 0 else { return nil }
                guard info.st_mode & S_IFMT == S_IFDIR else { continue }
                do {
                    if let id = try readBundleID(entry) { apps.append((entry, id)) }
                } catch { return nil }
            }
            if incomplete { return nil }
        }
        return apps
    }

    private static func inspectItem(_ url: URL, label: String, env: ScanEnvironment, isApp: Bool, expectedType: mode_t? = nil) -> Item? {
        guard let original = snapshot(url, env: env, isApp: isApp, expectedType: expectedType) else { return nil }
        let size = AllocatedSizer().size(of: url)
        guard size.unreadable.isEmpty, snapshot(url, env: env, isApp: isApp) == original else { return nil }
        return Item(url: url, label: label, bytes: size.bytes, snapshot: original)
    }

    fileprivate struct Stamp: Equatable, Sendable {
        let identity: FileIdentity
        let size: Int64
        let mode: mode_t
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let changedSeconds: Int
        let changedNanos: Int

        init(_ info: stat) {
            identity = FileIdentity(dev: info.st_dev, ino: info.st_ino)
            size = info.st_size
            mode = info.st_mode
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanos = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec
            changedNanos = info.st_ctimespec.tv_nsec
        }
    }

    private static func snapshot(_ url: URL, env: ScanEnvironment, isApp: Bool, expectedType: mode_t? = nil) -> [String: Stamp]? {
        guard SafetyGuard.checkRemovable(url, env: env) == nil,
              let home = FileIdentity(path: env.home.path) else { return nil }
        let fd = open(SafetyGuard.withoutSystemPathAlias(url.path), O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_dev == home.dev,
              expectedType.map({ info.st_mode & S_IFMT == $0 }) ?? true,
              info.st_uid == getuid() || (isApp && info.st_uid == 0),
              info.st_flags & UInt32(SF_DATALESS) == 0 else { return nil }
        let initial = Stamp(info)
        if !isApp, info.st_mode & S_IFMT == S_IFREG { return ["": initial] }
        guard info.st_mode & S_IFMT == S_IFDIR else { return nil }
        var result = ["": initial]
        var incomplete = false
        guard let entries = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil,
                                                           options: [], errorHandler: { _, _ in
            incomplete = true
            return false
        }) else { return nil }
        let prefix = SafetyGuard.withoutSystemPathAlias(url.path) + "/"
        for case let entry as URL in entries {
            let path = SafetyGuard.withoutSystemPathAlias(entry.path)
            guard path.hasPrefix(prefix), lstat(path, &info) == 0, info.st_dev == home.dev,
                  info.st_flags & UInt32(SF_DATALESS) == 0 else { return nil }
            let kind = info.st_mode & S_IFMT
            guard kind == S_IFDIR || kind == S_IFREG || kind == S_IFLNK else { return nil }
            if kind == S_IFLNK { entries.skipDescendants() }
            result[String(path.dropFirst(prefix.count))] = Stamp(info)
        }
        guard !incomplete, lstat(url.path, &info) == 0, Stamp(info) == initial else { return nil }
        return result
    }
}
