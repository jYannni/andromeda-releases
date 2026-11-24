import AndromedaAppModel
import AppKit
import SwiftUI

@MainActor
public final class StorageStatusItem: NSObject {
    public static let preference = "diskplain.storage.showMenuBarItem"

    private let model: AppModel
    private let openApp: () -> Void
    private let openTrends: () -> Void
    private let openTools: () -> Void
    private let openSettings: () -> Void
    private var item: NSStatusItem?
    private var panel: NSPanel?
    private var monitors: [Any] = []
    private var outsideMouseButton: Int?
    private var pendingDismissal: Task<Void, Never>?

    public init(model: AppModel, openApp: @escaping () -> Void, openTrends: @escaping () -> Void,
                openTools: @escaping () -> Void, openSettings: @escaping () -> Void) {
        self.model = model
        self.openApp = openApp
        self.openTrends = openTrends
        self.openTools = openTools
        self.openSettings = openSettings
    }

    public func setVisible(_ visible: Bool) {
        guard visible else {
            dismiss()
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            return
        }
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = menuBarGalaxy()
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Andromeda"
        let label = "\(appName) Storage"
        item.button?.toolTip = label
        item.button?.setAccessibilityLabel(label)
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        self.item = item
    }

    @objc private func togglePanel() {
        guard panel == nil else { dismiss(); return }
        guard let button = item?.button, let window = button.window, let screen = window.screen else { return }

        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let usable = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let top = min(usable.maxY, anchor.minY - 8)
        let width = min(358, usable.width)
        guard width > 0, top > usable.minY else { return }

        let content = StoragePanelView(model: model, openApp: { [weak self] in self?.perform(\.openApp) },
                                       openTrends: { [weak self] in self?.perform(\.openTrends) },
                                       openTools: { [weak self] in self?.perform(\.openTools) },
                                       openSettings: { [weak self] in self?.perform(\.openSettings) })
        let measured = NSHostingView(rootView: content.frame(width: width))
        let height = min(ceil(measured.fittingSize.height), top - usable.minY)
        let frame = NSRect(x: usable.maxX - width, y: top - height, width: width, height: height)
        let hosting = NSHostingView(rootView: StoragePanelSlide(content: content, size: frame.size))
        hosting.sizingOptions = []

        let panel = StoragePanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.title = "Andromeda Storage"
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        // Keep the actual window on-screen. Only the content moves during the reveal.
        panel.setFrame(frame, display: false)
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        monitorDismissal(panel: panel, button: button)
    }

    private func monitorDismissal(panel: NSPanel, button: NSStatusBarButton) {
        let clicks: NSEvent.EventTypeMask = [
            .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp,
        ]
        let handleClick: @MainActor (NSEvent) -> Void = { [weak self, weak panel, weak button] event in
            guard let self, let panel, self.panel === panel else { return }
            switch event.type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                let location = event.cgEvent?.unflippedLocation
                    ?? event.window?.convertPoint(toScreen: event.locationInWindow)
                    ?? event.locationInWindow
                let statusFrame = button.flatMap { view in view.window.map { window in
                    window.convertToScreen(view.convert(view.bounds, to: nil))
                }}
                let isOutside = !panel.frame.contains(location) && statusFrame?.contains(location) != true
                self.outsideMouseButton = isOutside ? event.buttonNumber : nil
            case .leftMouseUp, .rightMouseUp, .otherMouseUp:
                guard self.outsideMouseButton == event.buttonNumber else { return }
                self.outsideMouseButton = nil

                // The menu bar can forward its button action after the outside monitors see the click.
                // Wait for the release and give the button action a chance to close this panel itself.
                self.pendingDismissal?.cancel()
                self.pendingDismissal = Task { [weak self, weak panel] in
                    try? await Task.sleep(for: .milliseconds(120))
                    guard !Task.isCancelled, let self, let panel, self.panel === panel else { return }
                    self.dismiss()
                }
            default:
                break
            }
        }

        if let local = NSEvent.addLocalMonitorForEvents(matching: [clicks, .keyDown], handler: { [weak self] event in
            if event.type == .keyDown {
                if event.keyCode == 53 { self?.dismiss(); return nil }
            } else {
                handleClick(event)
            }
            return event
        }) { monitors.append(local) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { event in
            MainActor.assumeIsolated { handleClick(event) }
        }) { monitors.append(global) }
    }

    private func perform(_ action: KeyPath<StorageStatusItem, () -> Void>) {
        dismiss()
        self[keyPath: action]()
    }

    private func dismiss() {
        outsideMouseButton = nil
        pendingDismissal?.cancel()
        pendingDismissal = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }
}

private final class StoragePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct StoragePanelSlide: View {
    let content: StoragePanelView
    let size: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        ScrollView {
            content
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: size.width, height: size.height, alignment: .top)
        .offset(x: appeared || reduceMotion ? 0 : size.width)
        .clipped()
        .task {
            guard !reduceMotion else { return }
            await Task.yield()
            withAnimation(.easeOut(duration: 0.24)) { appeared = true }
        }
    }
}
