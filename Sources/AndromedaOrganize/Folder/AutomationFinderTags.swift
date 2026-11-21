import Darwin
import Foundation

enum AutomationFinderTags {
    enum Change {
        case unchanged, replace(Data), remove
    }

    static let attribute = "com.apple.metadata:_kMDItemUserTags"
    private static let maximumAttributeSize = 16 * 1_048_576

    static func readNames(_ name: String, in directory: Int32, expected: stat) -> [String]? {
        let fd = openat(directory, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        func matchesObservation() -> Bool {
            var current = stat()
            return fstat(fd, &current) == 0 && current.st_mode & S_IFMT == S_IFREG
                && current.st_dev == expected.st_dev && current.st_ino == expected.st_ino
                && current.st_uid == expected.st_uid && current.st_size == expected.st_size
                && current.st_flags & UInt32(SF_DATALESS | UF_HIDDEN) == 0
                && current.st_ctimespec.tv_sec == expected.st_ctimespec.tv_sec
                && current.st_ctimespec.tv_nsec == expected.st_ctimespec.tv_nsec
        }
        guard matchesObservation(), let tags = try? readStoredTags(at: fd, path: name),
              matchesObservation() else { return nil }
        let names = tags.map(Self.name(of:))
        guard names.allSatisfy({ !$0.isEmpty && FolderAutomationRule.isValidFinderTag($0) }) else { return nil }
        return names
    }

    /// Preserve the stored spelling and color of tags outside the requested changes.
    static func change(adding names: [String], removing removed: [String], at fd: Int32, path: String) throws -> Change {
        guard !names.isEmpty || !removed.isEmpty else { return .unchanged }
        let original = try readStoredTags(at: fd, path: path)
        var tags = original
        let removals = Set(removed.map(NamingRules.key))
        tags.removeAll { removals.contains(NamingRules.key(name(of: $0))) }
        var present = Set(tags.map { NamingRules.key(name(of: $0)) })
        for name in names where present.insert(NamingRules.key(name)).inserted {
            // Finder stores a color index after the name. Zero is uncolored.
            tags.append(name + "\n0")
        }
        guard tags != original else { return .unchanged }
        if tags.isEmpty { return .remove }
        return .replace(try PropertyListSerialization.data(fromPropertyList: tags, format: .binary, options: 0))
    }

    private static func readStoredTags(at fd: Int32, path: String) throws -> [String] {
        let length = fgetxattr(fd, attribute, nil, 0, 0, 0)
        if length < 0 {
            guard errno == ENOATTR else { throw ArchiveFailure.system(path, errno) }
            return []
        }
        guard length <= maximumAttributeSize else { throw ArchiveFailure.unsupportedSource(path) }
        var data = Data(count: length)
        guard data.withUnsafeMutableBytes({
            fgetxattr(fd, attribute, $0.baseAddress, length, 0, 0)
        }) == length else { throw ArchiveFailure.changed(path) }
        guard let stored = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let entries = stored as? [String] else { throw ArchiveFailure.unsupportedSource(path) }
        return entries
    }

    static func apply(_ change: Change, to fd: Int32, path: String) throws {
        switch change {
        case .unchanged: return
        case .replace(let data):
            guard data.withUnsafeBytes({ fsetxattr(fd, attribute, $0.baseAddress, $0.count, 0, 0) }) == 0 else {
                throw ArchiveFailure.system(path, errno)
            }
        case .remove:
            guard fremovexattr(fd, attribute, 0) == 0 || errno == ENOATTR else { throw ArchiveFailure.system(path, errno) }
        }
    }

    private static func name(of tag: String) -> String {
        guard let separator = tag.lastIndex(of: "\n"),
              let color = Int(tag[tag.index(after: separator)...]), (0...7).contains(color) else { return tag }
        return String(tag[..<separator])
    }
}
