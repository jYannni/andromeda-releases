import AndromedaCore

/// Turns a journal outcome into the sentence a receipt or History row shows. Shared by the
/// removal receipt and History so both say the same thing.
enum OutcomeText {
    /// `reversible` is true for a Trash move, false for a command. `appName` names the app for
    /// an "app was open" skip; nil falls back to "The app".
    static func text(for outcome: Outcome, reversible: Bool, appName: @autoclosure () -> String?) -> String {
        switch outcome {
        case .done: return reversible ? Copy.Receipt.movedToTrash : Copy.Receipt.done
        case .skipped(let reason): return text(for: reason, appName: appName())
        case .failed(let message): return reversible ? Copy.Receipt.couldntMove(message) : Copy.Receipt.problem(message)
        case .permanentlyDeleted: return Copy.Receipt.deleted
        case .restored: return Copy.Receipt.putBack
        case .planned: return Copy.Receipt.interrupted
        }
    }

    static func text(for reason: SkipReason, appName: String?) -> String {
        switch reason {
        case .changedSinceScan: return Copy.Receipt.skippedChanged
        case .appRunning: return Copy.Receipt.appWasOpen(appName ?? Copy.Receipt.theApp)
        case .applicationNotMoved: return "Left in place because the application wasn’t moved to Trash."
        case .backupNotVerified: return "Left in place because the backup copy couldn’t be verified."
        case .dependentMoveNotRestored: return "Backup kept until the remaining steps can be undone."
        case .backupSourceChanged: return "Backup kept because the original file changed or is unavailable."
        case .safetyViolation: return Copy.Receipt.safetyViolation
        case .alreadyGone: return Copy.Receipt.alreadyGone
        case .notOurs: return Copy.Receipt.notOurs
        case .helperUnavailable: return Copy.Receipt.helperUnavailable
        case .alreadyDoneThisBoot: return Copy.Receipt.alreadyDoneThisBoot
        case .interruptedNotMoved: return Copy.Receipt.notMoved
        case .destinationOccupied: return Copy.Receipt.skippedOccupied
        case .originalPathOccupied: return Copy.Receipt.skippedOriginalOccupied
        case .originalParentMissing: return Copy.Receipt.skippedParentMissing
        case .notEmpty: return Copy.Receipt.skippedNotEmpty
        case .crossVolume: return Copy.Receipt.skippedOtherDisk
        case .notWhereWeLeftIt: return Copy.Receipt.notWhereWeLeftIt
        case .volumeNotConnected: return Copy.Drives.driveNotConnected
        }
    }
}
