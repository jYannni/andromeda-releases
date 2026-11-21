import AppKit
import AndromedaAppModel
import AndromedaUI
import SwiftUI

@main
enum AndromedaMain {
    static func main() {
        // Hidden build check; runs before any UI, scan or journal exists.
        if CommandLine.arguments.contains("--self-test-catalog") {
            do {
                print(try SelfTest.catalogCount())
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("self-test failed: \(error)\n".utf8))
                exit(1)
            }
        }
        if CommandLine.arguments.contains("--self-test-release-history") {
            do {
                let entries = try ReleaseHistoryEntry.bundled()
                guard let latest = entries.first, entries.count > 1 else { throw CocoaError(.fileReadCorruptFile) }
                print(latest.version)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("release history self-test failed: \(error)\n".utf8))
                exit(1)
            }
        }
        // Report-only: prints the group plan for a folder and exits. Applies, writes and journals nothing.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--plan-groups") {
            guard i + 1 < args.count else {
                FileHandle.standardError.write(Data("usage: Andromeda --plan-groups <folder>\n".utf8))
                exit(1)
            }
            do {
                let folder = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath)
                let data = try GroupReport.run(folder: folder, env: .live())
                FileHandle.standardOutput.write(data + Data("\n".utf8))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("plan-groups failed: \(error)\n".utf8))
                exit(1)
            }
        }
        // One window, so no tab bar items in the View and Window menus.
        NSWindow.allowsAutomaticWindowTabbing = false
        AndromedaApp.main()
    }
}

@MainActor
private final class AndromedaLifecycle: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model = AppModel(deps: .live(), storageNotifications: StorageNotifications())
    let updates = UpdateController()
    static let automationMenuKey = "diskplain.folderAutomation.showMenuBarItem"
    private var statusItem: NSStatusItem?
    private var pauseItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        updates.start()
        model.storageMonitor.start()
        model.folderAutomation.start()
        Task { await model.startDriveMonitoring() }
        updateAutomationMenu(shown: UserDefaults.standard.bool(forKey: Self.automationMenuKey))
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.access.recheck()
        Task { await model.helper.appBecameActive() }
        Task { await model.storageMonitor.refreshNotificationStatus() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func updateAutomationMenu(shown: Bool) {
        if !shown {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            pauseItem = nil
            return
        }
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "folder.badge.gearshape",
                                    accessibilityDescription: "Andromeda Automation")
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "Andromeda Automation"
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        menu.addItem(menuItem("Open Andromeda", action: #selector(reopenFromMenu)))
        menu.addItem(.separator())
        let pause = menuItem("Pause Folder Automation", action: #selector(toggleAutomationPause))
        menu.addItem(pause)
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit Andromeda", action: #selector(quitFromMenu)))
        pauseItem = pause
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let automation = model.folderAutomation
        pauseItem?.title = automation.isAutomationPaused ? "Resume Folder Automation" : "Pause Folder Automation"
        pauseItem?.isEnabled = automation.available
    }

    private func menuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func reopenFromMenu() {
        NSWorkspace.shared.open(Bundle.main.bundleURL)
    }

    @objc private func toggleAutomationPause() {
        let automation = model.folderAutomation
        automation.setAutomationPaused(!automation.isAutomationPaused)
    }

    @objc private func quitFromMenu() { NSApp.terminate(nil) }
}

struct AndromedaApp: App {
    @NSApplicationDelegateAdaptor private var lifecycle: AndromedaLifecycle
    @State private var ui = UIState()
    @AppStorage(AndromedaLifecycle.automationMenuKey) private var showsAutomationMenu = false

    /// The verify build says so in its title, so screenshots can't be mistaken for the normal app.
    private static let windowTitle: String = {
        #if ANDROMEDA_VERIFY
        return "Andromeda — verification build"
        #else
        return "Andromeda"
        #endif
    }()

    var body: some Scene {
        let model = lifecycle.model
        let updates = lifecycle.updates
        WindowGroup(Self.windowTitle) {
            RootView(model: model, ui: ui, showUpdate: updates.updateAvailable ? { updates.showUpdate() } : nil)
                .frame(minWidth: 900, minHeight: 700)
        }
        .defaultSize(width: 1080, height: 780)
        .windowResizability(.contentMinSize)
        .commands {
            AppCommands(model: model, ui: ui)
        }
        Settings {
            SettingsView(model: model, updater: updates.updater, showsAutomationMenu: Binding(
                get: { showsAutomationMenu },
                set: {
                    showsAutomationMenu = $0
                    lifecycle.updateAutomationMenu(shown: $0)
                }
            ), showVersionHistory: updates.showVersionHistory)
            .windowResizeBehavior(.enabled)
        }
        .defaultSize(width: 730, height: 640)
        .windowResizability(.contentMinSize)
    }
}
