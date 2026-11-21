import AndromedaCore

extension PhotoLibraryReview {
    /// The selected and retained assets from one reviewed group, with their scanned revisions.
    public struct RemovalPlan: Sendable {
        public let selected: [SimilarImageScanner.LibraryPhoto]
        public let retained: [SimilarImageScanner.LibraryPhoto]

        fileprivate init(selected: [SimilarImageScanner.LibraryPhoto], retained: [SimilarImageScanner.LibraryPhoto]) {
            self.selected = selected
            self.retained = retained
        }
    }

    public static func makeRemovalPlan(
        from group: SimilarImageScanner.LibraryGroup, selectedIDs: Set<String>
    ) -> RemovalPlan? {
        guard !selectedIDs.isEmpty else { return nil }
        var seen: Set<String> = []
        var selected: [SimilarImageScanner.LibraryPhoto] = []
        var retained: [SimilarImageScanner.LibraryPhoto] = []
        for photo in group.photos {
            guard !photo.id.isEmpty, seen.insert(photo.id).inserted, photo.modificationDate != nil else { return nil }
            if selectedIDs.contains(photo.id) {
                selected.append(photo)
            } else {
                retained.append(photo)
            }
        }
        guard selected.count == selectedIDs.count, !retained.isEmpty else { return nil }
        return RemovalPlan(selected: selected, retained: retained)
    }
}
