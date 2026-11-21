import Foundation

/// A problem in one catalog file. `file` is the file name (or `<id>.json` for validation errors).
public struct CatalogError: Error, Equatable {
    public let file: String
    public let message: String

    public init(file: String, message: String) {
        self.file = file
        self.message = message
    }
}

public enum CatalogLoader {
    /// Decodes every `*.json` file in `directory`, validates, and returns entries most specific first.
    public static func load(directory: URL) throws -> [CatalogEntry] {
        let fm = FileManager.default
        let names: [String]
        do {
            let all = try fm.contentsOfDirectory(atPath: directory.path)
                .filter { !$0.hasPrefix(".") }
                .sorted()
            var json: [String] = []
            for name in all {
                var isDir: ObjCBool = false
                _ = fm.fileExists(atPath: directory.appendingPathComponent(name).path, isDirectory: &isDir)
                if isDir.boolValue { continue }
                guard name.hasSuffix(".json") else {
                    throw CatalogError(file: name, message: "unexpected file: catalog files must end in .json (lowercase)")
                }
                json.append(name)
            }
            names = json
        } catch let error as CatalogError {
            throw error
        } catch {
            throw CatalogError(file: directory.lastPathComponent, message: "cannot read catalog directory: \(error.localizedDescription)")
        }

        var entries: [CatalogEntry] = []
        var errors: [CatalogError] = []
        for name in names {
            do {
                let data = try Data(contentsOf: directory.appendingPathComponent(name))
                let entry = try JSONDecoder().decode(CatalogEntry.self, from: data)
                if name != "\(entry.id).json" {
                    errors.append(CatalogError(file: name, message: "file name must match id '\(entry.id)' (expected \(entry.id).json)"))
                }
                entries.append(entry)
            } catch {
                throw CatalogError(file: name, message: "cannot decode: \(describe(error))")
            }
        }
        if let first = errors.first { throw first }
        if let first = validate(entries).first { throw first }

        return entries.sorted {
            let (a, b) = (specificity($0), specificity($1))
            return a != b ? a > b : $0.id < $1.id
        }
    }

    public static func validate(_ entries: [CatalogEntry]) -> [CatalogError] {
        var errors: [CatalogError] = []
        var seen = Set<String>()
        let idPattern = /^[a-z0-9]+(-[a-z0-9]+)*$/

        for e in entries {
            func fail(_ message: String) { errors.append(CatalogError(file: "\(e.id).json", message: message)) }

            if e.id.wholeMatch(of: idPattern) == nil { fail("id '\(e.id)' must be lowercase kebab-case") }
            if !seen.insert(e.id).inserted { fail("duplicate id '\(e.id)'") }
            if e.sources.isEmpty { fail("sources must not be empty") }
            if !isValidDate(e.lastVerified) { fail("last_verified '\(e.lastVerified)' must be a yyyy-MM-dd date") }
            for (field, p) in e.paths.map({ ("path", $0) }) + e.exclude.map({ ("exclude", $0) }) {
                if !(p.hasPrefix("~/") || p.hasPrefix("/") || p.hasPrefix(ScanEnvironment.userVarFolderPrefix + "/")) {
                    fail("\(field) '\(p)' must start with ~/ or / (or \(ScanEnvironment.userVarFolderPrefix)/)")
                }
                if p.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) {
                    fail("\(field) '\(p)' must not contain '.' or '..' components")
                }
                if p.lowercased().hasPrefix("/users/") {
                    fail("\(field) '\(p)' is an absolute home path; write home paths with ~/")
                }
            }

            switch (e.tier, e.removal) {
            case (.safe, .trash), (.safe, .tool), (.safe, .deleteLocalSnapshots),
                 (.withCare, .trash), (.withCare, .tool), (.withCare, .deleteLocalSnapshots):
                break
            case (.safe, _), (.withCare, _):
                fail("tier '\(e.tier.rawValue)' requires removal trash, tool or delete-local-snapshots")
            case (.leaveIt, .handoff), (.leaveIt, .terminalCommand), (.leaveIt, .restart), (.leaveIt, .none),
                 (.cantRemove, .handoff), (.cantRemove, .terminalCommand), (.cantRemove, .restart), (.cantRemove, .none):
                break
            case (.leaveIt, _), (.cantRemove, _):
                fail("tier '\(e.tier.rawValue)' requires removal handoff, terminal-command, restart or none")
            }

            if case .tool(let executable, _) = e.removal {
                if !executable.hasPrefix("/") {
                    fail("tool executable '\(executable)' must be an absolute path")
                }
                if shells.contains(executable.lowercased()) {
                    fail("tool executable '\(executable)' is a shell; commands must not run through a shell")
                }
            }
            if let tool = e.requiresTool, !tool.hasPrefix("/") {
                fail("requires_tool '\(tool)' must be an absolute path")
            }

            if e.removal == .trash {
                for p in e.paths where isSystemOrProtected(p) {
                    fail("trash entry path '\(p)' is under /System or a protected store")
                }
            }
        }
        return errors
    }

    // MARK: - Helpers

    /// Characters before the first `*` or `?`.
    private static func literalPrefixLength(_ path: String) -> Int {
        path.firstIndex(where: { $0 == "*" || $0 == "?" })
            .map { path.distance(from: path.startIndex, to: $0) } ?? path.count
    }

    private static func specificity(_ e: CatalogEntry) -> Int {
        e.paths.map(literalPrefixLength).max() ?? 0
    }

    private static let shells: Set<String> = ["/bin/sh", "/bin/bash", "/bin/zsh", "/usr/bin/env"]

    /// The same shell deny-list, shared with `Executor` so there is exactly one copy.
    static var shellExecutables: Set<String> { shells }

    /// Uses the literal prefix (components before the first wildcard component), case-insensitively.
    /// Rejects /System, anything inside a protected store, and any ancestor of one.
    private static func isSystemOrProtected(_ path: String) -> Bool {
        let isHome = path.hasPrefix("~/")
        var parts = path.lowercased().split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if isHome { parts.removeFirst() }
        let prefix = Array(parts.prefix(while: { !$0.contains("*") && !$0.contains("?") }))
        let guarded: [[String]] = isHome
            ? SafetyGuard.protectedStoreRelativePaths.map { $0.lowercased().split(separator: "/").map(String.init) }
            : [["system"]]
        return guarded.contains { g in
            let n = min(g.count, prefix.count)
            return Array(g.prefix(n)) == Array(prefix.prefix(n))
        }
    }

    private static func isValidDate(_ s: String) -> Bool {
        guard s.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil else { return false }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        return f.date(from: s) != nil
    }

    private static func describe(_ error: Error) -> String {
        if let d = error as? DecodingError {
            switch d {
            case .keyNotFound(let k, _): return "missing key '\(k.stringValue)'"
            case .valueNotFound(_, let c), .typeMismatch(_, let c), .dataCorrupted(let c):
                let path = c.codingPath.map(\.stringValue).joined(separator: ".")
                return "\(c.debugDescription) at '\(path)'"
            @unknown default: break
            }
        }
        return error.localizedDescription
    }
}
