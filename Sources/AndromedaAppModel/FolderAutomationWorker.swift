import CoreFoundation
import Darwin
import AndromedaCore
import AndromedaHelperProtocol
import Foundation
import Security
import ServiceManagement

/// Entry point for the per-user LaunchAgent embedded in the signed app.
public enum FolderAutomationWorker {
    public static let serviceLabel = HelperIdentity.automationWorkerBundleID
    public static let plistName = serviceLabel + ".plist"
    public static let version = HelperIdentity.version
    private static let workerName = "diskplain-automation-worker"
    private static let idleInterval: TimeInterval = 30

    public static func run() {
        // A terminal invocation cannot take ownership just because an approved worker also exists.
        guard getuid() != 0, geteuid() == getuid(), getppid() == 1 else { return }
        let control = ScanControl { _ in }
        let events = SourceEvents()
        let signalWake = events.signal
        let signals = [SIGTERM, SIGINT].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .utility))
            source.setEventHandler { @Sendable in
                control.cancel()
                signalWake.notify()
            }
            source.resume()
            return source
        }
        defer { signals.forEach { $0.cancel() } }
        let journalDirectory = Journal.liveDirectory()
        let settings = FolderAutomationSettingsStore(journalDirectory: journalDirectory)
        let service = SMAppService.agent(plistName: plistName)
        var installed: InstalledWorker?
        run(env: .live(), settings: settings, journalDirectory: journalDirectory, trasher: LiveTrasher(),
            control: control, mayStart: {
                if installed?.isCurrent() == false { control.cancel(); return false }
                guard service.status == .enabled, rollbackFenceIsSet(), ownsLaunchdJob(control: control) else { return false }
                if installed == nil { installed = InstalledWorker.verify() }
                return installed != nil
            }, canContinue: {
                guard installed?.isCurrent() == true else { control.cancel(); return false }
                return true
            }, events: events, wait: { interval in
                _ = events.wait(for: interval)
            })
    }

    static func run(env: ScanEnvironment, settings: FolderAutomationSettingsStore, journalDirectory: URL,
                    trasher: any Trasher, control: ScanControl, mayStart: () -> Bool, canContinue: () -> Bool,
                    events: SourceEvents? = nil, wait: (TimeInterval) -> Void) {
        defer { events?.reconcile([:]) }
        var runner: FolderAutomationRunner?
        while !control.isCancelled {
            var interval = idleInterval
            if let snapshot = try? settings.load(), snapshot.mode == .afterQuit, mayStart(), !control.isCancelled {
                if let events {
                    events.reconcile(FolderAutomationRunner.watchableScopes(snapshot, env: env))
                }
                if runner == nil {
                    runner = try? FolderAutomationRunner(env: env, settings: settings,
                                                         journalDirectory: journalDirectory, trasher: trasher)
                }
                let checked = runner?.check(authorizes: { saved in
                    saved.mode == .afterQuit && saved.revision == snapshot.revision && canContinue()
                }, shouldContinue: { !control.isCancelled })
                if let next = checked?.nextCheck {
                    interval = min(idleInterval, max(0.05, next.timeIntervalSinceNow))
                }
            } else {
                events?.reconcile([:])
                runner = nil
            }
            if !control.isCancelled { wait(interval) }
        }
    }

    /// The worker owns the streams on its loop thread. Only the wake signal crosses queues.
    final class SourceEvents {
        private typealias Folder = AutomationDirectories.Folder
        private typealias Depth = FolderAutomationRunner.WatchDepth
        private let queue = DispatchQueue(label: "io.github.jyannni.diskplain.automation.events", qos: .utility)
        fileprivate let signal = WakeSignal()
        var watchFolderEvents = FileChangeWatch.startFolderEvents
        private var streams: [Folder: (depth: Depth, token: UUID, stream: AnyObject)] = [:]

        func reconcile(_ sources: Set<AutomationDirectories.Folder>) {
            reconcile(Dictionary(uniqueKeysWithValues: sources.map { ($0, .bounded(0)) }))
        }

        func reconcile(_ sources: [AutomationDirectories.Folder: FolderAutomationRunner.WatchDepth]) {
            let invalidated = signal.takeDiscontinuities()
            for (folder, watch) in streams where sources[folder] != watch.depth || invalidated.contains(watch.token) {
                signal.remove(watch.token)
                streams.removeValue(forKey: folder)
            }
            for (folder, depth) in sources where streams[folder] == nil {
                let maximumDepth: Int? = switch depth {
                case .bounded(let limit): limit
                case .unlimited: nil
                }
                let token = UUID()
                signal.insert(token)
                guard let stream = watchFolderEvents(folder, maximumDepth, queue, { [signal] change in
                    signal.notify(token: token, discontinuity: change == .discontinuity)
                }), let fd = folder.openCurrent() else {
                    signal.remove(token)
                    continue
                }
                close(fd)
                streams[folder] = (depth, token, stream)
            }
        }

        @discardableResult
        func wait(for interval: TimeInterval) -> Bool { signal.wait(for: interval) }
        func wake() { signal.notify() }
    }

    final class WakeSignal: @unchecked Sendable {
        private let condition = NSCondition()
        private var active: Set<UUID> = []
        private var invalidated: Set<UUID> = []
        private var pending: Set<UUID> = []
        private var manuallyWoken = false

        func insert(_ token: UUID) {
            condition.withLock { _ = active.insert(token) }
        }

        func remove(_ token: UUID) {
            condition.withLock {
                active.remove(token)
                invalidated.remove(token)
                pending.remove(token)
            }
        }

        func takeDiscontinuities() -> Set<UUID> {
            condition.withLock {
                let result = invalidated
                invalidated.removeAll()
                return result
            }
        }

        func notify(token: UUID? = nil, discontinuity: Bool = false) {
            condition.withLock {
                if let token {
                    guard active.contains(token) else { return }
                    if discontinuity { invalidated.insert(token) }
                    pending.insert(token)
                } else {
                    manuallyWoken = true
                }
                condition.signal()
            }
        }

        func wait(for interval: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(interval)
            return condition.withLock {
                while pending.isEmpty && !manuallyWoken {
                    if !condition.wait(until: deadline) { break }
                }
                let signaled = !pending.isEmpty || manuallyWoken
                pending.removeAll()
                manuallyWoken = false
                return signaled
            }
        }
    }

    private static func rollbackFenceIsSet() -> Bool {
        let domain = HelperIdentity.appBundleID as CFString
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost),
              let value = CFPreferencesCopyValue(FolderAutomationLegacySettings.pausedKey as CFString, domain,
                                                 kCFPreferencesCurrentUser, kCFPreferencesAnyHost),
              CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
        return value as? Bool == true
    }

    private static func ownsLaunchdJob(control: ScanControl) -> Bool {
        let deadline = DispatchTime.now() + .seconds(2)
        let stillChecking = { !control.isCancelled && DispatchTime.now() < deadline }
        guard let result = try? LiveToolRunner().run(
            URL(fileURLWithPath: "/bin/launchctl"), ["list"], wakeOnExit: true, shouldContinue: stillChecking
        ), result.exitCode == 0, stillChecking() else { return false }
        return listsWorker(result.stdout, pid: getpid())
    }

    /// `launchctl list` documents PID, status and label columns in the caller's bootstrap domain.
    static func listsWorker(_ output: String, pid: pid_t) -> Bool {
        guard pid > 1 else { return false }
        let matches = output.split(whereSeparator: \.isNewline).map { $0.split(whereSeparator: \.isWhitespace) }.filter {
            $0.count == 3 && $0[2] == serviceLabel
        }
        return matches.count == 1 && pid_t(matches[0][0]) == pid
    }

    private struct InstalledWorker {
        let stamps: [URL: FileStamp]

        func isCurrent() -> Bool { stamps.allSatisfy { FileStamp(url: $0.key) == $0.value } }

        static func verify() -> InstalledWorker? {
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let length = path.withUnsafeMutableBytes { proc_pidpath(getpid(), $0.baseAddress, UInt32($0.count)) }
            guard length > 0, let name = path.withUnsafeBufferPointer({ String(validatingCString: $0.baseAddress!) })
            else { return nil }
            let worker = URL(fileURLWithPath: name).resolvingSymlinksInPath()
            let macOS = worker.deletingLastPathComponent()
            let contents = macOS.deletingLastPathComponent()
            let app = contents.deletingLastPathComponent()
            let main = macOS.appendingPathComponent("Andromeda")
            let info = contents.appendingPathComponent("Info.plist")
            guard worker.lastPathComponent == workerName, macOS.lastPathComponent == "MacOS",
                  contents.lastPathComponent == "Contents", app.pathExtension == "app",
                  let workerStamp = FileStamp(url: worker), let mainStamp = FileStamp(url: main),
                  let infoStamp = FileStamp(url: info),
                  let host = Bundle(url: app), host.bundleIdentifier == HelperIdentity.appBundleID,
                  host.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version.split(separator: "+").first.map(String.init),
                  let appRequirement = HelperIdentity.makeAppRequirement(),
                  let workerRequirement = HelperIdentity.makeAutomationWorkerRequirement()
            else { return nil }

            var running: SecCode?, runningStatic: SecStaticCode?, onDisk: SecStaticCode?, hostCode: SecStaticCode?
            guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
                  SecCodeCheckValidity(running, [], workerRequirement) == errSecSuccess,
                  SecCodeCopyStaticCode(running, [], &runningStatic) == errSecSuccess, let runningStatic,
                  SecStaticCodeCreateWithPath(worker as CFURL, [], &onDisk) == errSecSuccess, let onDisk,
                  SecStaticCodeCheckValidity(onDisk, [], workerRequirement) == errSecSuccess,
                  let runningHash = hash(runningStatic), runningHash == hash(onDisk),
                  SecStaticCodeCreateWithPath(app as CFURL, [], &hostCode) == errSecSuccess, let hostCode,
                  SecStaticCodeCheckValidity(hostCode, [], appRequirement) == errSecSuccess
            else { return nil }
            let installed = InstalledWorker(stamps: [worker: workerStamp, main: mainStamp, info: infoStamp])
            return installed.isCurrent() ? installed : nil
        }

        private static func hash(_ code: SecStaticCode) -> Data? {
            var info: CFDictionary?
            guard SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
                  let values = info as? [String: Any] else { return nil }
            return values[kSecCodeInfoUnique as String] as? Data
        }
    }

    private struct FileStamp: Equatable {
        let identity: FileIdentity
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init?(url: URL) {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
            identity = FileIdentity(dev: info.st_dev, ino: info.st_ino)
            size = info.st_size
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanoseconds = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec
            changedNanoseconds = info.st_ctimespec.tv_nsec
        }
    }
}
