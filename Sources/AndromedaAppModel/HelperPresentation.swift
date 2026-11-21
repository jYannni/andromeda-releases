import Foundation

/// The one thing the helper's button does in a given state.
public enum HelperAction: Equatable, Sendable {
    case turnOn
    case setUpAgain

    /// Turning on goes through the explainer sheet; setting up again runs straight away.
    public var needsExplainer: Bool { self == .turnOn }

    /// Title in Settings.
    public var settingsTitle: String {
        switch self {
        case .turnOn: Copy.Helper.turnOnSettings
        case .setUpAgain: Copy.Helper.setUpAgain
        }
    }

    /// Title on the helper sheet.
    public var sheetTitle: String {
        switch self {
        case .turnOn: Copy.Helper.turnOn
        case .setUpAgain: Copy.Helper.setUpAgain
        }
    }
}

/// Everything the helper sheet and Settings show for a state, decided here so views decide nothing (P24).
extension HelperState {
    public var statusText: String {
        switch self {
        case .off: Copy.Helper.off
        case .waitingForApproval: Copy.Helper.waiting
        case .checking: Copy.Helper.checking
        case .ready: Copy.Helper.ready
        case .dead: Copy.Helper.dead
        case .needsReapproval(let reason): reason
        case .failed(let message): message
        }
    }

    /// "Turn on" when off; "Set up again" when dead, needing re-approval or failed (P13); nothing otherwise.
    public var action: HelperAction? {
        switch self {
        case .off: .turnOn
        case .dead, .needsReapproval, .failed: .setUpAgain
        case .waitingForApproval, .checking, .ready: nil
        }
    }

    /// Removing makes sense whenever something is registered or was tried.
    public var canRemove: Bool { self != .off }

    /// "Not now" before anything happened, "Close" once the helper has moved on.
    public var dismissTitle: String { self == .off ? Copy.Helper.notNow : Copy.Helper.close }

    /// What the sheet says under the explainer; nil while the helper is off and nothing has been tried.
    public var sheetNote: String? { self == .off ? nil : statusText }
}

extension HelperModel {
    /// Carries out `action` (the view only forwards the press).
    public func perform(_ action: HelperAction) async {
        switch action {
        case .turnOn: await turnOn()
        case .setUpAgain: await recover()
        }
    }
}
