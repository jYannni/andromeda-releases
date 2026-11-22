import AppKit
import AndromedaAppModel
import AndromedaUI
import Foundation
import Observation
import Sparkle
import SwiftUI

/// Local builds and hand-delivered betas can ship without an update feed.
@MainActor @Observable
final class UpdateController: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var feedConfiguration: [String]?
    @ObservationIgnored private var enrollsInPublicBetaOnFirstLaunch = false
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var historyWindow: NSWindow?
    private static let availabilityKey = "io.github.jyannni.diskplain.available-update"
    private static let publicBetaKey = "io.github.jyannni.diskplain.receive-public-betas"
    private static let publicBetaChannel = "public-beta"

    private(set) var updateAvailable = false
    private(set) var receivesPublicBetas = false
    private(set) var offersPublicBetas = false
    var updater: SPUUpdater? { controller?.updater }

    private var feedContext: [String]? {
        feedConfiguration.map { $0 + (receivesPublicBetas ? [Self.publicBetaChannel] : []) }
    }

    init(bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        let settings = bundle.infoDictionary ?? [:]
        guard let feed = settings["SUFeedURL"] as? String,
              let url = URLComponents(string: feed), url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil,
              let key = settings["SUPublicEDKey"] as? String, Data(base64Encoded: key)?.count == 32,
              settings["SURequireSignedFeed"] as? Bool == true,
              settings["SUVerifyUpdateBeforeExtraction"] as? Bool == true else {
            return
        }
        let channel = settings["AndromedaReleaseChannel"] as? String
        offersPublicBetas = channel == "public-release" || channel == Self.publicBetaChannel
        enrollsInPublicBetaOnFirstLaunch = channel == Self.publicBetaChannel
            && defaults.object(forKey: Self.publicBetaKey) == nil
        receivesPublicBetas = offersPublicBetas
            && (defaults.bool(forKey: Self.publicBetaKey) || enrollsInPublicBetaOnFirstLaunch)
        feedConfiguration = [feed, key, settings["CFBundleVersion"] as? String ?? "", channel ?? ""]
        updateAvailable = feedContext == defaults.stringArray(forKey: Self.availabilityKey)
        controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
    }

    func start() {
        guard let controller, !started else { return }
        started = true
        if enrollsInPublicBetaOnFirstLaunch { defaults.set(true, forKey: Self.publicBetaKey) }
        controller.updater.clearFeedURLFromUserDefaults()
        controller.startUpdater()
    }

    func showUpdate() {
        controller?.checkForUpdates(nil)
    }

    func setReceivesPublicBetas(_ value: Bool) {
        guard offersPublicBetas, value != receivesPublicBetas,
              let updater, !updater.sessionInProgress else { return }
        receivesPublicBetas = value
        defaults.set(value, forKey: Self.publicBetaKey)
        setAvailability(false)
        updater.resetUpdateCycleAfterShortDelay()
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        // The signed build's feed takes precedence over old shared Sparkle preferences.
        feedConfiguration?.first
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        receivesPublicBetas ? [Self.publicBetaChannel] : []
    }

    func showVersionHistory() {
        if historyWindow == nil {
            let view = WhatsNewView(releases: (try? ReleaseHistoryEntry.bundled()) ?? [])
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 525, height: 620),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "What’s New"
            window.contentView = NSHostingView(rootView: view)
            window.contentMinSize = NSSize(width: 360, height: 340)
            window.isReleasedWhenClosed = false
            window.center()
            historyWindow = window
        }
        historyWindow?.makeKeyAndOrderFront(nil)
    }

    nonisolated func standardUserDriverShowVersionHistory(for item: SUAppcastItem) {
        Task { @MainActor [weak self] in self?.showVersionHistory() }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        setAvailability(true)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        setAvailability(false)
    }

    func updater(
        _ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice,
        forUpdate item: SUAppcastItem, state: SPUUserUpdateState
    ) {
        if choice == .skip { setAvailability(false) }
    }

    private func setAvailability(_ available: Bool) {
        updateAvailable = available
        defaults.set(available ? feedContext : nil, forKey: Self.availabilityKey)
    }
}
