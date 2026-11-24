import Darwin
import Foundation

public enum ToolCleanup: Sendable {
    case aiClutter, mailAttachments

    public struct Item: Identifiable, Sendable {
        public var id: URL { url }
        public let url: URL
        public let title: String
        public let detail: String
        public var isLocalModel: Bool { kind == .aiClutter && url.pathExtension.lowercased() == "gguf" }
        public var bytes: Int64 { tree.bytes }
        let tree: ReviewedFileTree
        let kind: ToolCleanup
        let quit: [String]
        let mailOriginal: URL?
        let mailDigest: Data?
    }

    public struct Review: Sendable {
        public let items: [Item]
        public let preserved: Int
        public let incomplete: Bool
    }

    struct Check: Equatable, Sendable {
        let url: URL
        let tree: ReviewedFileTree
        let mailOriginal: URL?
        let mailDigest: Data?

        func verify(st: stat) -> Bool {
            guard ReviewedFileTree.Stamp(st) == tree.root, ReviewedFileTree.capture(url) == tree else { return false }
            if let mailOriginal, let mailDigest {
                return ToolCleanup.fingerprint(mailOriginal) == mailDigest
                    && ToolCleanup.fingerprint(url) == mailDigest && ReviewedFileTree.capture(url) == tree
            }
            return true
        }
    }

    var catalogID: String {
        switch self {
        case .aiClutter: "ai-clutter"
        case .mailAttachments: "reviewed-mail-attachments"
        }
    }

    public func scan(env: ScanEnvironment, protectedReadable: Bool, control: ScanControl) -> Review {
        switch self {
        case .aiClutter: Self.scanAI(env: env, control: control)
        case .mailAttachments:
            protectedReadable ? Self.scanMail(env: env, control: control)
                : Review(items: [], preserved: 0, incomplete: true)
        }
    }

    public static func plan(_ items: [Item], selected: Set<URL>) -> RemovalPlan? {
        let paths = Set(selected.map { SafetyGuard.withoutSystemPathAlias($0.standardizedFileURL.path) })
        let removals = items.filter { paths.contains(SafetyGuard.withoutSystemPathAlias($0.url.path)) }.map { item in
            PlannedRemoval(catalogEntryID: item.kind.catalogID, action: .moveToTrash(item.url),
                           expectedBytes: item.bytes, expectation: nil, appsMustBeQuit: item.quit,
                           toolCleanupCheck: Check(url: item.url, tree: item.tree, mailOriginal: item.mailOriginal,
                                                   mailDigest: item.mailDigest))
        }
        return removals.isEmpty ? nil : RemovalPlan(removals: removals)
    }

    private struct Source {
        let title: String
        let paths: [String]
        let apps: [String]

        init(_ title: String, _ paths: [String], apps: [String] = []) {
            self.title = title
            self.paths = paths
            self.apps = apps
        }
    }

    // These are narrow cache/log paths. Provider configuration, chats, credentials and model blobs
    // shared with other Ollama models are outside the sweep.
    private static let sources: [Source] = [
        Source("Codex", ["Library/Caches/com.openai.codex", ".codex/log"], apps: ["com.openai.codex"]),
        Source("Claude Code", [".claude/debug"]),
        Source("Claude", ["Library/Caches/com.anthropic.claudefordesktop",
                          "Library/Application Support/Claude/Cache",
                          "Library/Application Support/Claude/Code Cache",
                          "Library/Application Support/Claude/GPUCache",
                          "Library/Logs/Claude"], apps: ["com.anthropic.claudefordesktop"]),
        Source("Cursor", ["Library/Caches/com.todesktop.230313mzl4w4u92",
                          "Library/Application Support/Cursor/Cache",
                          "Library/Application Support/Cursor/Code Cache",
                          "Library/Application Support/Cursor/GPUCache",
                          "Library/Application Support/Cursor/logs"], apps: ["com.todesktop.230313mzl4w4u92"]),
        Source("ChatGPT", ["Library/Caches/com.openai.chat"], apps: ["com.openai.chat"]),
        Source("LM Studio", ["Library/Caches/ai.elementlabs.lmstudio",
                             "Library/Application Support/LM Studio/Cache",
                             "Library/Application Support/LM Studio/Code Cache",
                             "Library/Application Support/LM Studio/GPUCache"], apps: ["ai.elementlabs.lmstudio"]),
        Source("Hugging Face", [".cache/huggingface/hub", ".cache/huggingface/datasets", ".cache/huggingface/xet"]),
    ]

    private static func scanAI(env: ScanEnvironment, control: ScanControl) -> Review {
        var items: [Item] = []
        var preserved = 0
        for source in sources {
            for path in source.paths where !control.isCancelled {
                let url = env.home.appendingPathComponent(path)
                var info = stat()
                if lstat(url.path, &info) != 0, errno == ENOENT { continue }
                guard SafetyGuard.checkRemovable(url, env: env) == nil,
                      let tree = ReviewedFileTree.capture(url, control: control), tree.root.kind == S_IFDIR,
                      FileIdentity(path: env.home.path)?.dev == tree.root.identity.dev else { preserved += 1; continue }
                if tree.bytes > 0 {
                    items.append(Item(url: url, title: source.title + " · " + url.lastPathComponent, detail: path,
                                      tree: tree, kind: .aiClutter, quit: source.apps, mailOriginal: nil, mailDigest: nil))
                }
            }
        }
        let modelPath = env.home.appendingPathComponent(".lmstudio/models", isDirectory: true).path
        let models = URL(fileURLWithPath: SafetyGuard.withoutSystemPathAlias(modelPath), isDirectory: true)
        var incomplete = false
        walk(models, control: control, incomplete: &incomplete) { url, info in
            let relative = url.pathComponents.dropFirst(models.pathComponents.count)
            guard relative.count == 3, url.pathExtension.lowercased() == "gguf" else { return }
            guard url.lastPathComponent.firstMatch(of: /-\d{5}-of-\d{5}\.gguf$/) == nil,
                  SafetyGuard.checkRemovable(url, env: env) == nil,
                  let tree = ReviewedFileTree.capture(url, control: control),
                  tree.root == ReviewedFileTree.Stamp(info) else { preserved += 1; return }
            items.append(Item(url: url, title: "LM Studio · " + url.lastPathComponent,
                              detail: "Imported models may be your only copy.", tree: tree, kind: .aiClutter,
                              quit: ["ai.elementlabs.lmstudio"], mailOriginal: nil, mailDigest: nil))
        }
        return Review(items: items.sorted { $0.bytes > $1.bytes }, preserved: preserved, incomplete: incomplete)
    }

    private struct Match: Hashable {
        let name: String
        let size: Int64
    }

    private static func scanMail(env: ScanEnvironment, control: ScanControl) -> Review {
        let downloads = env.home.appendingPathComponent("Library/Containers/com.apple.mail/Data/Library/Mail Downloads")
        let store = env.home.appendingPathComponent("Library/Mail")
        var incomplete = false
        var preserved = 0
        let local = files(under: downloads, control: control, incomplete: &incomplete)
        if local.isEmpty { return Review(items: [], preserved: 0, incomplete: incomplete) }
        let candidates = Dictionary(grouping: local, by: \.key)
        var verified: [URL: (original: URL, digest: Data)] = [:]
        walk(store, control: control, incomplete: &incomplete) { original, info in
            let ancestry = original.pathComponents.dropLast()
            guard ancestry.contains("Attachments"), ancestry.contains(where: { $0.hasSuffix(".mbox") }),
                  let copies = candidates[Match(name: original.lastPathComponent, size: info.st_size)],
                  copies.contains(where: { verified[$0.url] == nil }),
                  let digest = fingerprint(original, info: info, control: control) else { return }
            for copy in copies where verified[copy.url] == nil {
                if fingerprint(copy.url, info: copy.info, control: control) == digest {
                    verified[copy.url] = (original, digest)
                }
            }
        }
        let items = local.compactMap { copy -> Item? in
            guard let match = verified[copy.url], SafetyGuard.checkRemovable(copy.url, env: env) == nil,
                  let tree = ReviewedFileTree.capture(copy.url, control: control),
                  tree.root == ReviewedFileTree.Stamp(copy.info) else { preserved += 1; return nil }
            return Item(url: copy.url, title: copy.url.lastPathComponent, detail: "Matches a copy in Apple Mail",
                        tree: tree, kind: .mailAttachments, quit: ["com.apple.mail"],
                        mailOriginal: match.original, mailDigest: match.digest)
        }
        return Review(items: items.sorted { $0.bytes > $1.bytes }, preserved: preserved, incomplete: incomplete)
    }

    private static func files(under root: URL, control: ScanControl, incomplete: inout Bool)
        -> [(url: URL, key: Match, info: stat)] {
        var result: [(url: URL, key: Match, info: stat)] = []
        walk(root, control: control, incomplete: &incomplete) { url, info in
            result.append((url, Match(name: url.lastPathComponent, size: info.st_size), info))
        }
        return result
    }

    private static func walk(_ root: URL, control: ScanControl, incomplete: inout Bool,
                             file: (URL, stat) -> Void) {
        let fd = ReviewedFileTree.openDirectory(root)
        guard fd >= 0 else { if errno != ENOENT { incomplete = true }; return }
        defer { close(fd) }
        var rootInfo = stat()
        guard fstat(fd, &rootInfo) == 0 else { incomplete = true; return }
        var failed = false
        guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                           options: [.skipsHiddenFiles], errorHandler: { _, _ in
            failed = true
            return true
        }) else { incomplete = true; return }
        for case let url as URL in entries {
            if control.isCancelled { return }
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_dev == rootInfo.st_dev,
                  info.st_flags & UInt32(SF_DATALESS) == 0 else {
                entries.skipDescendants()
                failed = true
                continue
            }
            if info.st_mode & S_IFMT == S_IFLNK { entries.skipDescendants() }
            if info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() {
                file(URL(fileURLWithPath: SafetyGuard.withoutSystemPathAlias(url.path)), info)
            }
        }
        incomplete = incomplete || failed
    }

    private static func fingerprint(_ url: URL, info: stat? = nil,
                                    control: ScanControl = ScanControl { _ in }) -> Data? {
        var value = stat()
        if let info { value = info } else if lstat(url.path, &value) != 0 { return nil }
        return DuplicateScanner.fullDigest(at: url, info: value, control: control)
    }
}
