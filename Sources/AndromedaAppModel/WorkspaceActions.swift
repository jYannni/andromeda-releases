import AppKit
import Foundation

/// Everything the app asks of the desktop: opening links, revealing files, the pasteboard, save panels.
public protocol WorkspaceActions: Sendable {
    func open(_ url: URL) -> Bool
    func reveal(_ url: URL)
    /// One Finder window with all of `urls` selected.
    func revealMany(_ urls: [URL])
    func copy(_ string: String)
    func saveFile(suggestedName: String, contents: Data) async -> Bool
    /// The open panel, folders only. nil when the user cancels.
    func chooseFolder() async -> URL?
    func chooseFolder(startingAt directory: URL) async -> URL?
    func chooseFolders() async -> [URL]
}

public extension WorkspaceActions {
    func chooseFolder(startingAt directory: URL) async -> URL? { await chooseFolder() }
    func chooseFolders() async -> [URL] {
        guard let folder = await chooseFolder() else { return [] }
        return [folder]
    }
}

public struct LiveWorkspaceActions: WorkspaceActions {
    public init() {}

    public func open(_ url: URL) -> Bool { NSWorkspace.shared.open(url) }

    public func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    public func revealMany(_ urls: [URL]) { NSWorkspace.shared.activateFileViewerSelecting(urls) }

    public func copy(_ string: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(string, forType: .string)
    }

    public func saveFile(suggestedName: String, contents: Data) async -> Bool {
        await MainActor.run {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = suggestedName
            guard panel.runModal() == .OK, let url = panel.url else { return false }
            do {
                try contents.write(to: url, options: .atomic)
                return true
            } catch {
                return false
            }
        }
    }

    public func chooseFolder() async -> URL? { await selectFolders(startingAt: nil, multiple: false).first }

    public func chooseFolder(startingAt directory: URL) async -> URL? {
        await selectFolders(startingAt: directory, multiple: false).first
    }

    public func chooseFolders() async -> [URL] { await selectFolders(startingAt: nil, multiple: true) }

    private func selectFolders(startingAt directory: URL?, multiple: Bool) async -> [URL] {
        await MainActor.run {
            let panel = NSOpenPanel()
            if let directory { panel.directoryURL = directory }
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = multiple
            panel.canCreateDirectories = false
            guard panel.runModal() == .OK else { return [] }
            return panel.urls
        }
    }
}
