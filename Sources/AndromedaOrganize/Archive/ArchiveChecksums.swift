import CryptoKit
import AndromedaCore
import Foundation

enum ArchiveChecksums {
    struct Seal: Codable, Equatable, Sendable {
        let digest: Data
        let bytes: Int64
    }

    static func name(beside payload: String, legacy: Bool = false) -> String {
        let brand = legacy ? "Diskplain" : "Andromeda"
        let standard = "\(brand) Checksums.sha256"
        return payload.caseInsensitiveCompare(standard) == .orderedSame ? "\(brand) File Checksums.sha256" : standard
    }

    /// Tagged SHA-256 keeps a trailing carriage return inside the parentheses, where readers
    /// preserve it. Both shasum and GNU sha256sum understand escaped backslashes and newlines.
    private static let hex = Array("0123456789abcdef".utf8)

    static func appendTaggedLine(relativePath: String, digest: Data, to buffer: inout Data) {
        let escaped = relativePath.utf8.contains { $0 == 92 || $0 == 10 }
        if escaped { buffer.append(92) }
        buffer.append(contentsOf: "SHA256 (".utf8)
        for byte in relativePath.utf8 {
            if byte == 92 || byte == 10 { buffer.append(92) }
            buffer.append(byte == 10 ? 110 : byte)
        }
        buffer.append(contentsOf: ") = ".utf8)
        for byte in digest {
            buffer.append(hex[Int(byte >> 4)])
            buffer.append(hex[Int(byte & 0x0f)])
        }
        buffer.append(10)
    }

    final class Writer {
        private let file: FileHandle
        private let path: String
        private let payload: String
        private var buffer = Data()
        private var hash = SHA256()
        private var bytes: Int64 = 0

        init(directory: Int32, path: String, payload: String) throws {
            self.path = path
            self.payload = payload
            let fd = openat(directory, ArchiveChecksums.name(beside: payload),
                            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw ArchiveFailure.system(path, errno) }
            file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            buffer.reserveCapacity(65_536)
        }

        func append(relativePath: String, digest: Data) throws {
            let relative = "./" + payload + (relativePath.isEmpty ? "" : "/" + relativePath)
            ArchiveChecksums.appendTaggedLine(relativePath: relative, digest: digest, to: &buffer)
            if buffer.count >= 65_536 { try flush() }
        }

        func finish() throws -> Seal {
            try flush()
            guard fsync(file.fileDescriptor) == 0 else { throw ArchiveFailure.system(path, errno) }
            return Seal(digest: Data(hash.finalize()), bytes: bytes)
        }

        private func flush() throws {
            guard !buffer.isEmpty else { return }
            try file.write(contentsOf: buffer)
            hash.update(data: buffer)
            bytes += Int64(buffer.count)
            buffer.removeAll(keepingCapacity: true)
        }
    }

    static func verify(_ seal: Seal, directory: Int32, filename: String, device: dev_t, control: ScanControl) throws {
        let fd = openat(directory, filename, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ArchiveFailure.portableChecksumsMismatch }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_dev == device, before.st_size == seal.bytes else {
            throw ArchiveFailure.portableChecksumsMismatch
        }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var hash = SHA256()
        var bytes: Int64 = 0
        while bytes < seal.bytes {
            try ArchiveTree.check(control)
            let count = Int(min(65_536, seal.bytes - bytes))
            guard let block = try file.read(upToCount: count), !block.isEmpty else {
                throw ArchiveFailure.portableChecksumsMismatch
            }
            bytes += Int64(block.count)
            hash.update(data: block)
        }
        var after = stat()
        var current = stat()
        guard fstat(fd, &after) == 0, after.st_size == before.st_size,
              after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec,
              fstatat(directory, filename, &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_dev == before.st_dev, current.st_ino == before.st_ino,
              Data(hash.finalize()) == seal.digest else {
            throw ArchiveFailure.portableChecksumsMismatch
        }
    }
}
