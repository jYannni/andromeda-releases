import Foundation

enum SimilarImageCleanup {
    static let catalogID = "cleanup.similar-image"

    static func canTrash(_ photo: SimilarImageScanner.Photo, env: ScanEnvironment) -> Bool {
        var info = stat()
        return lstat(photo.url.path, &info) == 0 && matches(photo, info: info, env: env)
    }

    private static func matches(_ photo: SimilarImageScanner.Photo, info: stat, env: ScanEnvironment) -> Bool {
        guard DuplicateScanner.matches(photo.candidate, info),
              DuplicateScanner.unchanged(photo.scanStat, info),
              info.st_uid == getuid(), info.st_nlink == 1,
              let home = FileIdentity(path: env.home.path), info.st_dev == home.dev,
              DuplicateScanner.canTrash(photo.url, env: env), photo.isCurrent() else { return false }

        var trash = stat()
        guard lstat(env.trash.path, &trash) == 0, trash.st_mode & S_IFMT == S_IFDIR,
              trash.st_uid == getuid(), trash.st_dev == info.st_dev else { return false }
        var url = photo.url
        url.removeAllCachedResourceValues()
        guard let attributes = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .volumeIsLocalKey]),
              attributes.volumeIsLocal == true, attributes.isUbiquitousItem != true else { return false }
        return true
    }

    struct TrashCheck: Equatable, Sendable {
        let photo: SimilarImageScanner.Photo
        let keeper: SimilarImageScanner.Photo

        var url: URL { photo.url }
        var allocatedBytes: Int64 { Int64(photo.scanStat.st_blocks) * 512 }

        func verify(_ info: stat, env: ScanEnvironment) -> Bool {
            keeper.isCurrent() && SimilarImageCleanup.matches(photo, info: info, env: env)
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.photo.candidate == rhs.photo.candidate && lhs.keeper.candidate == rhs.keeper.candidate
                && DuplicateScanner.unchanged(lhs.photo.scanStat, rhs.photo.scanStat)
                && DuplicateScanner.unchanged(lhs.keeper.scanStat, rhs.keeper.scanStat)
        }
    }

    static func checks(
        group: SimilarImageScanner.Group, selected: Set<URL>, env: ScanEnvironment
    ) -> [TrashCheck]? {
        guard !selected.isEmpty, selected.isSubset(of: group.trashCandidates),
              let keeper = group.photos.first(where: { !selected.contains($0.url) && $0.isCurrent() }) else { return nil }
        let photos = group.photos.filter { selected.contains($0.url) }
        guard photos.allSatisfy({ canTrash($0, env: env) }) else { return nil }
        return photos.map { TrashCheck(photo: $0, keeper: keeper) }
    }
}
