import AndromedaAppModel
import Foundation

/// Every user-facing string in the UI module lives here (spec §4), so localisation can be added later.
enum UICopy {
    static let appName = "Andromeda"

    // Sidebar and toolbar
    static let overview = "Overview"
    static let history = "History"
    static let storageGroup = "Storage"
    static let archivesTitle = "External Archives"
    static let archivesSubtitle = "Copy projects or camera footage to an external APFS drive, verify each copy, and find archived files even when the drive is unplugged."
    static let settingsGeneral = "General"
    static let helpOnGitHub = "Andromeda on GitHub"
    static let projectURL = URL(string: "https://github.com/jYannni/andromeda-releases")!
    static let historySubtitle = "See what changed and which items you can put back."
    static let historyEmptyTitle = "No history yet"
    static let noCloudTitle = "No cloud folders found"
    static let organizeEmptyTitle = "Choose a folder to organize"
    static let organizeEmptyBody = "Andromeda proposes a plan first. You see every move, and nothing changes until you apply it."
    static let scan = "Scan"
    static let scanAgain = "Scan again"
    static let scanHelp = "Measure the disk again. Scanning only reads sizes and names."
    static func scannedAt(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? "Scanned at \(date.formatted(date: .omitted, time: .shortened))"
            : "Scanned \(date.formatted(date: .abbreviated, time: .shortened))"
    }
    static let tryAgain = "Try again"

    // Scanning
    static let scanningTitle = "Scanning your Mac"
    static let scanningNote = "Andromeda only reads sizes and names. Nothing is changed."
    static let scanDetails = "Details"
    static let cancelScan = "Cancel scan"
    static let stoppingScan = "Stopping…"
    static func nowReading(_ path: String) -> String { "Reading \(path)" }
    static func nowLookingAt(_ entry: String) -> String { "Looking at \(entry)" }
    static func stageState(_ state: ScanningView.RowState) -> String {
        switch state {
        case .done: "done"
        case .running: "in progress"
        case .waiting: "waiting"
        }
    }
    static func stage(_ stage: ScanStage) -> String {
        switch stage {
        case .checkingAccess: "Checking what Andromeda can read"
        case .catalog: "Looking through known locations"
        case .helperMeasure: "Measuring protected folders and other accounts"
        case .largeItems: "Finding large files"
        case .applications: "Sizing your apps"
        case .outsideHome: "Measuring folders outside your home folder"
        case .volume: "Reading the disk's totals"
        case .reconciling: "Adding it all up"
        }
    }
    static let readyTitle = "Ready when you are"
    static let readyBody = "Scan your Mac to see what is using the space and what you can do about it."
    static let failedTitle = "The scan didn't finish"

    // Onboarding
    static let welcomeTitle = "Welcome to Andromeda"
    static let welcomeSubtitle = "See what’s using space and find options to make room."
    static let scanPrivacy = "The scan stays on your Mac and leaves your files in place."
    static let accessTitle = "Optional Full Disk Access"
    static let accessBody = "Full Disk Access lets Andromeda measure more protected folders, including Mail and Messages. You can grant it later from Overview."
    static let accessOn = "Full Disk Access is on"
    static let openSettings = "Open System Settings"
    static let scanMyMac = "Scan my Mac"
    static let scanWithLimitedAccess = "Scan with limited access"
    static let dismiss = "Dismiss"

    // Overview
    static let overviewTitle = "Overview"
    static let overviewSubtitle = "What is using your disk, and what you can safely remove."
    static let quickWinsTitle = "Cleanup suggestions"
    static let quickWinsSubtitle = "Select the items below, then review what moves to Trash."
    static let cardsHeading = "Worth knowing"
    static let whatYouCanDo = "What you can do"
    static func probablyCounted(_ bucketTitle: String) -> String { "Probably counted as \(bucketTitle)" }

    // Drive pages (plan 7)
    static func driveSubtitle(kind: String?, format: String) -> String {
        kind.map { "\($0) · \(format)" } ?? format
    }
    static let driveUsed = "Used"
    static let apfsFileAllocation = "File sizes show allocated bytes. Files that share APFS data can each include that allocation."
    static let driveIdleBody = "Scan this drive to see what's on it. Scanning only reads sizes and names."
    static func driveScanning(_ name: String) -> String { "Scanning \(name)…" }
    static let driveHiddenHeading = "Hidden space"
    static let driveHiddenSubtitle = "Folders macOS keeps on this drive."
    static let driveLargeHeading = "Large items"
    static let driveNotConnectedBody = "Connect it again to see what's on it."
    static let thisDrive = "This drive"

    // Category pages
    static func pageTitle(_ title: String) -> String { "What's inside \(title)" }
    static let pageSubtitle = "Sorted by size. Each row says what it is, whether you can remove it, and how."
    static let largeHeading = "Large items here"
    static let largeSubtitle = "Your own files. Andromeda only shows where they are."

    // Rows
    static let afterwardsLabel = "Afterwards"
    static let howRemovedLabel = "How it's removed"
    static let copyCommand = "Copy command"
    static let open = "Open"
    static let rebuild = "Rebuild…"
    static let showInFinder = "Show in Finder"
    static let reviewMoveToCloud = "Review move to cloud"
    static let organizeThisFolder = "Organize this folder"

    static let letAndromedaDoIt = Copy.Helper.letAndromedaDoIt

    // Confirm, receipt, history
    static let cancel = "Cancel"
    static let done = "Done"
    static let confirmHeading = "Review before anything moves"
    static let confirmSubtitle = "Everything below happens when you confirm. Nothing else is touched."
    static let removing = "Removing"
    static func progress(done: Int, total: Int) -> String { "\(done) of \(total) done" }
    static let nothingRemoved = "Nothing was removed."
    static let putBack = "Put back"
    static let deletePermanently = "Delete these permanently\u{2026}"
    static let deleteConfirm = "Delete permanently"

    // Settings
    static let exportHeading = "Report"
    static let exportSubtitle = "The redacted report omits names and paths. Detailed reports can contain identifying information."
    static let exportSupport = "Export redacted report…"
    static let exportDetailed = "Detailed report"
    static let exportText = "Export report as text\u{2026}"
    static let exportJSON = "Export report as JSON\u{2026}"
}
