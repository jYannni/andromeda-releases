import AndromedaCore
import Foundation

/// The ubiquity resource values of one file, as the OS reports them.
public struct UbiquityKeys: Equatable, Sendable {
    public var isUbiquitous: Bool
    /// Downloading status is `.current` or `.downloaded`.
    public var downloaded: Bool
    public var uploaded: Bool
    public var uploading: Bool
    public var hasConflicts: Bool
    /// Domain and code of the upload error, e.g. `NSCocoaErrorDomain 4355`. Never shown (rev 3.5).
    public var uploadError: String?

    public init(
        isUbiquitous: Bool, downloaded: Bool, uploaded: Bool, uploading: Bool,
        hasConflicts: Bool, uploadError: String?
    ) {
        self.isUbiquitous = isUbiquitous
        self.downloaded = downloaded
        self.uploaded = uploaded
        self.uploading = uploading
        self.hasConflicts = hasConflicts
        self.uploadError = uploadError
    }
}

/// Organize 1 never reads pin state: always `.unknown`.
public enum PinState: Equatable, Sendable { case unknown, pinned, notPinned }

public enum SyncState: Equatable, Sendable {
    case synced, stillSyncing, conflict
    /// Present and online-only: a dataless folder, or files the OS reports as not downloaded.
    /// Never an empty folder, a symlink or an item that couldn't be read.
    case notDownloaded
    /// Nothing is at the path any more (`lstat` reports ENOENT or ENOTDIR). Never offered, never "in the cloud".
    case missing
}

public struct CloudItemState: Equatable, Sendable {
    public let url: URL
    public let provider: CloudProvider
    public let sync: SyncState
    public let isUploading: Bool
    public let pin: PinState
    /// Allocated bytes.
    public let usesBytes: Int64
    /// Private bytes: what offloading frees at least. nil = can't be measured.
    public let freesAtLeast: Int64?
    public let clonesPresent: Bool
    /// Regular files counted.
    public let fileCount: Int

    public init(
        url: URL, provider: CloudProvider, sync: SyncState, pin: PinState, usesBytes: Int64,
        freesAtLeast: Int64?, clonesPresent: Bool, fileCount: Int, isUploading: Bool = false
    ) {
        self.url = url
        self.provider = provider
        self.sync = sync
        self.isUploading = isUploading
        self.pin = pin
        self.usesBytes = usesBytes
        self.freesAtLeast = freesAtLeast
        self.clonesPresent = clonesPresent
        self.fileCount = fileCount
    }
}

/// Reads sync state and private bytes for a cloud file or folder. Local reads only.
public struct CloudItemInspector {
    private let readKeys: (URL) -> UbiquityKeys?
    private let size: (URL) -> SizeResult
    /// Test seam: `lstat` of a listed child; 0 on success, else the errno. FileManager won't list a folder
    /// whose children it can't reach, so a non-ENOENT failure here can't be staged on disk.
    var lstatChild: (String, inout stat) -> Int32 = { path, st in lstat(path, &st) == 0 ? 0 : errno }

    public init(
        readKeys: @escaping (URL) -> UbiquityKeys? = CloudItemInspector.liveKeys,
        size: @escaping (URL) -> SizeResult = { AllocatedSizer().size(of: $0) }
    ) {
        self.readKeys = readKeys
        self.size = size
    }

    public func inspect(_ url: URL, provider: CloudProvider) -> CloudItemState {
        var flags = Flags()
        var st = stat()
        if lstat(url.path, &st) == 0 {
            switch st.st_mode & S_IFMT {
            case S_IFREG: visit(url, into: &flags)
            case S_IFDIR:
                // A dataless folder is never entered: it is present and online-only.
                if st.st_flags & UInt32(SF_DATALESS) == 0 { walk(url, into: &flags) } else { flags.dataless = true }
            default:
                flags.syncing = true  // a symlink or special file: its upload can't be confirmed
            }
        } else if errno == ENOENT || errno == ENOTDIR {
            return CloudItemState(
                url: url, provider: provider, sync: .missing, pin: .unknown,
                usesBytes: 0, freesAtLeast: nil, clonesPresent: false, fileCount: 0)
        } else {
            flags.syncing = true  // there but unreadable: fail closed
        }
        let sync: SyncState =
            flags.conflict ? .conflict
            : flags.syncing ? .stillSyncing
            : flags.anyDownloaded ? .synced
            // Only something genuinely online-only is notDownloaded; an empty folder confirms nothing.
            : flags.files > 0 || flags.dataless ? .notDownloaded : .stillSyncing
        let sizes = size(url)
        return CloudItemState(
            url: url, provider: provider, sync: sync, pin: .unknown,
            usesBytes: sizes.bytes, freesAtLeast: sizes.privateBytes,
            clonesPresent: sizes.clonesPresent, fileCount: flags.files, isUploading: flags.uploading)
    }

    private struct Flags {
        var files = 0
        var conflict = false
        var syncing = false
        var uploading = false
        var anyDownloaded = false
        /// A dataless folder was seen (the item itself or one inside it).
        var dataless = false
    }

    private func visit(_ file: URL, into flags: inout Flags) {
        // Finder litter: ignored for sync state and not counted (its bytes still come from `size`).
        if file.lastPathComponent == ".DS_Store" { return }
        flags.files += 1
        // No keys means the OS would not say: never offered.
        guard let k = readKeys(file) else { flags.syncing = true; return }
        if k.hasConflicts { flags.conflict = true }
        if k.uploading { flags.uploading = true }
        if !k.uploaded || k.uploading || k.uploadError != nil { flags.syncing = true }
        if k.downloaded { flags.anyDownloaded = true }
    }

    /// lstat-based walk: skips symlinks and does not enter dataless directories.
    private func walk(_ dir: URL, into flags: inout Flags) {
        // An unreadable folder can't be confirmed uploaded: fail closed.
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            flags.syncing = true
            return
        }
        for name in names {
            let child = dir.appendingPathComponent(name)
            var st = stat()
            let failure = lstatChild(child.path, &st)
            guard failure == 0 else {
                // Gone since the listing: nothing to confirm. Any other failure can't be confirmed uploaded.
                if failure != ENOENT { flags.syncing = true }
                continue
            }
            switch st.st_mode & S_IFMT {
            case S_IFREG: visit(child, into: &flags)
            case S_IFDIR:
                if st.st_flags & UInt32(SF_DATALESS) != 0 { flags.dataless = true; continue }
                walk(child, into: &flags)
            default: continue
            }
        }
    }

    /// Reads the ubiquity keys from the file system. nil when the item is not ubiquitous.
    public static func liveKeys(_ url: URL) -> UbiquityKeys? {
        let keys: Set<URLResourceKey> = [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsUploadedKey,
            .ubiquitousItemIsUploadingKey, .ubiquitousItemHasUnresolvedConflictsKey,
            .ubiquitousItemUploadingErrorKey,
        ]
        guard let v = try? url.resourceValues(forKeys: keys), v.isUbiquitousItem == true else { return nil }
        let status = v.ubiquitousItemDownloadingStatus
        let error = v.ubiquitousItemUploadingError.map { "\($0.domain) \($0.code)" }
        return UbiquityKeys(
            isUbiquitous: true,
            downloaded: status == .current || status == .downloaded,
            uploaded: v.ubiquitousItemIsUploaded ?? false,
            uploading: v.ubiquitousItemIsUploading ?? false,
            hasConflicts: v.ubiquitousItemHasUnresolvedConflicts ?? false,
            uploadError: error)
    }
}
