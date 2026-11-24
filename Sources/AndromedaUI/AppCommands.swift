import AppKit
import AndromedaAppModel
import SwiftUI

/// The single-window app keeps Scan Again under File and page shortcuts in the Go menu.
public struct AppCommands: Commands {
    let model: AppModel
    let ui: UIState

    public init(model: AppModel, ui: UIState) {
        self.model = model
        self.ui = ui
    }

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(model.scan.lastResult == nil ? UICopy.scan : UICopy.scanAgain) {
                Task { await model.scan() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!model.canScan)
        }
        CommandMenu("Go") {
            Button(UICopy.overview) { ui.destination = .overview }
                .keyboardShortcut("1", modifiers: .command)
            Button(UICopy.history) { ui.destination = .history }
                .keyboardShortcut("2", modifiers: .command)
            Button(Copy.Organize.cloudTitle) { ui.destination = .cloud }
                .keyboardShortcut("3", modifiers: .command)
            Button(Copy.Organize.moveToCloudTitle) { ui.destination = .moveToCloud }
                .keyboardShortcut("4", modifiers: .command)
            Button(Copy.Organize.organizeFolderTitle) { ui.destination = .organizeFolder }
                .keyboardShortcut("5", modifiers: .command)
            Button("Tools") { ui.destination = .tools }
                .keyboardShortcut("6", modifiers: .command)
            Divider()
            Button("Search Drive Catalogs") { ui.focusCatalogSearch() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(!model.hasCompletedOnboarding || model.drives.catalogs.isEmpty)
        }
        CommandGroup(replacing: .sidebar) {
            Button(ui.sidebarIsCompact ? "Expand Sidebar" : "Minimize Sidebar") {
                ui.sidebarIsCompact.toggle()
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .disabled(!model.hasCompletedOnboarding)
        }
        CommandGroup(replacing: .help) {
            Button(UICopy.helpOnGitHub) { NSWorkspace.shared.open(UICopy.projectURL) }
        }
    }

}
