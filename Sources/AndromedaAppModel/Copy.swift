import Foundation
import AndromedaCore
import AndromedaOrganize

/// Every user-facing string in the app model lives here (spec §4), so localisation can be added later.
public enum Copy {
    /// The scanning screen's live line and details.
    public enum Scan {
        public static func counts(items: Int, bytes: Int64) -> String {
            let n = items.formatted(.number.grouping(.automatic))
            return "\(n) \(items == 1 ? "file" : "files") checked · \(ByteFormat.string(bytes)) measured"
        }

        public static func elapsed(seconds: Int) -> String {
            if seconds < 60 { return "Running for \(seconds) s" }
            let minutes = seconds / 60
            if minutes < 60 { return "Running for \(minutes) min" }
            return "Running for \(minutes / 60) h \(minutes % 60) min"
        }

        /// Home-relative (`~/…`) for paths inside home; other paths as they are.
        public static func displayPath(_ url: URL, home: URL) -> String {
            let path = url.standardizedFileURL.path
            let base = home.standardizedFileURL.path
            if path == base { return "~" }
            return path.hasPrefix(base + "/") ? "~" + path.dropFirst(base.count) : path
        }
    }

    public enum Verdicts {
        public static let safe = "Safe to remove"
        public static let withCare = "Remove with care"
        public static let leaveIt = "Leave it"
        public static let cantRemove = "Can't be removed"
    }

    public enum Page {
        /// Rev G: for pages with no catalog rows to act on (Applications, macOS, pages of only your own files).
        public static let readOnlySubtitle = "These are shown so you can see where the space is. Andromeda doesn't remove them."
    }

    public enum Rows {
        public static func notVerified(_ osMajor: Int) -> String { "Not yet verified on macOS \(osMajor)" }
        public static func toolMissing(_ tool: String) -> String { "Needs `\(tool)`, which isn't installed on this Mac." }
        public static let unlistedTitle = "Other files in your home folder"
        public static let unlistedNote = "Not listed one by one"
        public static let macOSVolumes = "MacOS system volumes"
        public static let otherApps = "Other apps"
        public static func otherAppsDetail(_ count: Int) -> String { "\(count) smaller \(count == 1 ? "app" : "apps")" }
        public static let sizeNotMeasured = "Size not measured"
        public static let cantMeasure = "Can't measure"
        public static let couldntRead = "Couldn't read"
        public static let blockedSuffix = " macOS protects this folder, even from Andromeda's helper."
        public static func snapshots(_ n: Int) -> String { n == 1 ? "1 snapshot" : "\(n) snapshots" }
        public static func atLeast(_ size: String) -> String { "at least \(size)" }
        public static func uses(_ size: String) -> String { "uses \(size)" }
        public static func frees(_ size: String) -> String { "frees at least \(size) (shared, estimate)" }
        public static let freesUnknown = "space it frees can't be measured"
        public static let sharedNote = "Includes shared disk space. Removing it may free less than shown."
        public static let commandSizeNote = "How much this frees depends on what the command removes."
    }

    /// Rev H: the read-only lines for space outside the home folder and other accounts.
    public enum Outside {
        public static let heading = "Outside your home folder"
        public static func title(_ row: OutsideRow) -> String { row.title }
        public static func otherUser(_ name: String) -> String { "Other user: \(name)" }
        public static let sizeNeedsHelper = "size needs the helper"
        public static let adminOnly = "Only an administrator account can see their size."
        /// "Other user: tester — 12.3 GB", for VoiceOver.
        public static func line(_ title: String, _ size: String) -> String { "\(title) — \(size)" }
    }

    public enum HowRemoved {
        public static let trash = "Moves to Trash"
        public static let snapshots = "Runs `tmutil deletelocalsnapshots` for each snapshot"
        public static let restart = "Restart your Mac"
        public static let nothing = "Nothing to do"
        public static func tool(_ executable: String, _ arguments: [String]) -> String {
            "Runs `\(([executable] + arguments).joined(separator: " "))`"
        }
        public static let helperRebuildsSpotlight = "Andromeda's helper rebuilds the Spotlight index (`mdutil -E /System/Volumes/Data`)"
        public static func copyCommand(_ command: String) -> String { "Copy `\(command)` into Terminal" }
    }

    public enum Overview {
        public static let couldntCheckHeading = "Couldn't check — needs Full Disk Access"
        public static let totalsUnknown =
            "Andromeda couldn't read this disk's totals, so it can't show how the space adds up. Everything it found is listed below."
        public static func used(_ used: String, of capacity: String) -> String { "\(used) used of \(capacity)" }
        public static func ofCapacity(_ capacity: String) -> String { "used of \(capacity)" }
        public static func available(_ size: String) -> String { "\(size) available" }
        public static func unaccounted(_ size: String) -> String { "\(size) isn't accounted for" }
        public static let nothingUnaccounted = "No gap between measured and used space"
        public static func overcount(_ size: String) -> String {
            "Category totals exceed used space by \(size)"
        }
        public static func segmentAccessibility(_ title: String, size: String, percent: String,
                                                showsCategoryAllocation: Bool = false) -> String {
            "\(title), \(size), \(percent) of \(showsCategoryAllocation ? "the category chart" : "used")"
        }
        public static let lessThanOnePercent = "less than 1%"
        public static func found(_ found: String, of used: String) -> String { "Andromeda found \(found) of \(used)" }
        public static func scannedAllocation(_ size: String) -> String { "\(size) allocated across scanned categories" }
        public static let allocationNote = "The chart adds up file and folder sizes. APFS can share the same disk space between files."
        public static func purgeableNote(_ size: String) -> String {
            "Plus \(size) purgeable (estimate): macOS frees this on its own, and Storage settings counts it as available."
        }
        public static let barUnaccounted = "Not accounted for"

        public static func cleanupSectorTitle(_ kind: CleanupSector.Kind) -> String {
            switch kind {
            case .projectBuilds: "Project build folders"
            case .appCaches: "App caches"
            case .packageCaches: "Package manager caches"
            case .xcodeCaches: "Xcode caches"
            case .simulatorCaches: "Simulator caches"
            case .logs: "Logs and diagnostic reports"
            case .mailDownloads: "Mail attachment downloads"
            case .modelCaches: "Model download caches"
            case .xcodeArchives: "Xcode archives"
            case .temporaryFiles: "Temporary files and caches"
            case .iosSimulators: "iOS and other Apple simulators"
            case .androidEmulators: "Android emulators"
            case .downloads: "Downloads"
            case .other: "Other cleanup items"
            }
        }
    }

    public enum Buckets {
        public static func title(_ bucket: AppleBucket) -> String {
            switch bucket {
            case .systemData: "System Data"
            case .documents: "Documents"
            case .developer: "Developer"
            case .iosFiles: "iOS Files"
            case .mail: "Mail"
            case .messages: "Messages"
            case .photos: "Photos"
            case .icloudDrive: "iCloud Drive"
            case .macOS: "MacOS"
            case .otherUsers: "Other Users & Shared"
            case .applications: "Applications"
            }
        }
    }

    public enum Cards {
        public static let purgeableTitle = "Purgeable space"
        public static let purgeableBody =
            "Purgeable space is cached and temporary data that macOS removes on its own when it needs the room. Storage settings counts it as available rather than used, and so does Andromeda. It can grow by tens of gigabytes without any new files."
        public static let purgeableDo =
            "You don't need to do anything. macOS frees this space on its own when something needs it."

        public static let appleIntelligenceTitle = "Apple Intelligence models"
        public static let appleIntelligenceBody =
            "Apple Intelligence keeps its on-device models on your Mac, usually 14 to 30 GB. On macOS 27, no supported setting or app can turn them off or remove them, so Andromeda shows them and doesn't offer to remove them."
        public static let appleIntelligenceDo =
            "Nothing to remove here. If you need the room, look at the other items in your list first."

        public static let orphanedRuntimesTitle = "Orphaned simulator runtimes"
        public static let orphanedRuntimesBody =
            "macOS protects simulator system assets. Andromeda can ask Xcode to remove registered runtimes that Xcode marks as removable. Orphaned assets that Xcode no longer lists may still use space."
        public static let orphanedRuntimesDo =
            "Review runtimes listed under iOS and other Apple simulators or in Xcode Settings › Components."

        public static let pendingUpdateTitle = "A macOS update is holding space"
        public static let pendingUpdateBody =
            "A pending or downloaded macOS update keeps space in local snapshots and in the Preboot volume until it finishes or is cancelled."
        public static let pendingUpdateDo =
            "Finish or cancel the pending macOS update, then restart."
    }
}

extension Copy {
    public enum Helper {
        public static let dead =
            "The helper is switched on but isn't answering. Andromeda can set it up again; you'll be asked to switch it on in Login Items."
        public static let updated = "Andromeda was updated, so its helper needs to be set up again."
        public static let relogin =
            "The helper is switched on but this login session can't reach it. Log out and back in, then try again."
        public static let notFound =
            "This copy of Andromeda doesn't include its helper, so it can't be turned on here. Reinstalling Andromeda restores it."
        public static let waiting =
            "The helper is waiting for your approval. Switch Andromeda on in Login Items, then come back."
        public static let registerFailed =
            "Andromeda couldn't set up its helper. Nothing was changed. You can try again from Settings."
        public static let recoverLeftOff =
            "Andromeda removed the old helper but couldn't set it up again, so the helper is now off. Press Turn on helper to try again."
        public static let otherCopy =
            "Another copy of Andromeda may be answering. Remove other copies of Andromeda, then set up the helper again."
        public static let title = "Andromeda's helper"
        public static let whatItIs =
            "A small background program that lets Andromeda measure folders macOS keeps to itself. It is optional and off until you turn it on."
        public static let whatItDoes =
            "It does exactly four things: it measures the size of system folders you can't read, as totals only; for an administrator, it measures the size of other accounts' folders, as totals with no file names; it rebuilds the Spotlight index, at most once per startup; and it reports its version."
        public static let whatItCant =
            "It can't delete or move your files, and it only answers to Andromeda."
        public static let howToRemove =
            "To remove it, choose Settings › Remove helper. You can also switch it off in Login Items."
        public static let explainer = [whatItIs, whatItDoes, whatItCant, howToRemove].joined(separator: " ")
        public static let turnOn = "Turn on helper"

        // Settings and the helper sheet (Task 12).
        public static let off = "The helper is off. Andromeda works without it; some system folders and other accounts' folders just aren't measured."
        public static let checking = "Checking the helper."
        public static let ready = "The helper is on."
        public static let turnOnSettings = "Turn on helper\u{2026}"
        public static let setUpAgain = "Set up helper again"
        public static let notNow = "Not now"
        public static let close = "Close"
        public static let letAndromedaDoIt = "Let Andromeda do it\u{2026}"
        public static let removeButton = "Remove helper\u{2026}"
        public static let removeTitle = "Remove the helper?"
        public static let removeBody =
            "Andromeda stops using the helper and switches it off in Login Items. Scanning still works; some system folders and other accounts' folders are marked as not measured."
        public static let removeConfirm = "Remove helper"
        public static let cancel = "Cancel"
    }
}

extension Copy {
    public enum Confirm {
        public static func review(_ n: Int) -> String { n == 1 ? "Review 1 item" : "Review \(n) items" }
        public static let rebuildSpotlight = "Rebuild Spotlight index"
        public static let commandSizeNotShown = "Size not shown"
        public static func runCommands(_ n: Int) -> String { n == 1 ? "Run 1 command" : "Run \(n) commands" }
        public static func moveAndRun(size: String?, commands n: Int) -> String {
            "Move \(size ?? "items") to Trash and run \(n) command\(n == 1 ? "" : "s")"
        }
        public static let irreversibleNote =
            "Commands can't be undone. Items moved to the Trash can be put back from History."
        public static func quitFirst(names: [String], items: Int) -> String {
            "Quit \(list(names)) first, or \(items == 1 ? "this item" : "those items") will be skipped."
        }
        /// "A", "A and B", "A, B and C".
        static func list(_ names: [String]) -> String {
            guard names.count > 1, let last = names.last else { return names.first ?? "" }
            return names.dropLast().joined(separator: ", ") + " and " + last
        }
        /// Several items from one entry are told apart by their file names.
        public static func itemTitle(_ entry: String, _ item: String) -> String { "\(entry): \(item)" }
        /// `atLeast`: some items share space with clones, so `size` is their private floor (spec §7.1 rev 2).
        public static func deletePermanentlyTitle(_ size: String?, atLeast: Bool = false) -> String {
            guard let size else { return "Delete these items permanently?" }
            return atLeast ? "Delete at least \(size) permanently?" : "Delete \(size) permanently?"
        }
        public static let deletePermanentlyBody =
            "Only the items Andromeda moved in this batch are deleted. Everything else in the Trash stays."
    }

    public enum History {
        /// Shown until the first load of the history finishes, instead of `empty`.
        public static let loading = "Loading history…"
        public static let empty = "Nothing has been removed yet. When Andromeda moves something to the Trash, it shows up here."
        public static let recordUnavailable =
            "Andromeda couldn't read its record of removals, so there is no history to show."
        public static func unreadable(_ n: Int) -> String {
            n == 1 ? "1 line of the history couldn't be read." : "\(n) lines of the history couldn't be read."
        }
        /// `shared`: some items share space with clones, so `size` is what they use, not what comes back.
        public static func summary(items: Int, size: String?, shared: Bool = false) -> String {
            let count = items == 1 ? "1 item" : "\(items) items"
            return size.map { "\(count) \u{00B7} \(shared ? Rows.uses($0) : $0)" } ?? count
        }
        public static let restoreOccupied = "Something is already at the original location. Move or rename it, then try again."
        public static let restoreParentMissing = "The original folder is gone, so this can't be put back there."
        public static let restoreReconnect = "Reconnect the original drive to put this file back."
        public static let restoreFailed = "Andromeda couldn't put this back."
        public static let restoreGone = "This item can't be put back any more."
        public static let deleteFailed = Receipt.deleteFailed
    }

    public enum Receipt {
        public static let movedToTrash = "Moved to Trash"
        public static let done = "Done"
        public static let skippedChanged = "Skipped: it changed since the scan. Scan again to see it as it is now."
        public static func appWasOpen(_ app: String) -> String { "Skipped: \(app) was open. Quit it and try again." }
        public static let theApp = "The app"
        public static let safetyViolation = "Skipped: Andromeda doesn't remove anything in this location."
        public static let alreadyGone = "Already gone"
        public static let notOurs = "Skipped: Andromeda didn't put this in the Trash."
        public static let helperUnavailable = "Skipped: the helper isn't on. You can turn it on in Settings."
        public static let alreadyDoneThisBoot =
            "Already rebuilt since your Mac started. Restart before rebuilding again."
        public static let deleted = "Deleted"
        public static let putBack = "Put back"
        // Organize apply and recovery outcomes, one per SkipReason (carry-forward P5). An interrupted
        // folder that can't be proven ours (R7) reads as "already there", never "moved elsewhere".
        public static let skippedOccupied = "Skipped: something with this name is already there."
        public static let skippedOriginalOccupied = "Skipped: something is already at the original location."
        public static let skippedParentMissing = "Skipped: the folder it goes into is missing."
        public static let skippedNotEmpty = "Skipped: the folder isn't empty."
        public static let skippedOtherDisk = "Skipped: on another disk — not in this version."
        public static let notWhereWeLeftIt = "Not where we left it — left alone."
        public static let notMoved = "Not moved: Andromeda stopped before reaching this item."
        /// A `planned` row nothing settled yet: the run stopped mid-item.
        public static let interrupted = "Interrupted: Andromeda stopped while handling this item."
        public static let notAttempted = "Not attempted: Andromeda stopped before reaching this item."
        private static func firstLine(_ message: String) -> String {
            String((message.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? "").prefix(200))
        }
        public static func problem(_ message: String) -> String {
            "The command reported a problem: \(firstLine(message))"
        }
        public static func couldntMove(_ message: String) -> String {
            "Couldn't move this to the Trash: \(firstLine(message))"
        }
        public static let refusedStale = "Nothing was removed because the list changed. Scan again and review it."
        public static let refusedScanning = "Nothing was removed because a scan is running. Try again when it finishes."
        public static let stopped =
            "Andromeda stopped because it couldn't write its record of removals. The items listed were handled; the rest weren't touched."
        public static let inTrashNoSize = "These items still use storage while they’re in the Trash."
        /// `atLeast`: some items share space with clones, so `size` is their private floor (spec §7.1 rev 2).
        public static func inTrash(_ size: String, atLeast: Bool = false) -> String {
            let estimate = atLeast ? "at least \(size)" : size
            return "\(inTrashNoSize) Permanently deleting them could make \(estimate) more space available."
        }
        public static let deleteFailed =
            "Andromeda couldn't finish deleting. Nothing else in the Trash was touched. You can try again."
        public static let commandsNote = "Commands can't be undone."
        public static let nothingRemoved = "Nothing was removed"
        public static func movedItems(_ n: Int) -> String { n == 1 ? "Moved 1 item to the Trash" : "Moved \(n) items to the Trash" }
        public static func ranCommands(_ n: Int) -> String { n == 1 ? "Ran 1 command" : "Ran \(n) commands" }
        public static func headline(moved: Int, ran: Int, skipped: Int, problems: Int) -> String {
            var parts: [String] = []
            if moved > 0 { parts.append(movedItems(moved)) }
            if ran > 0 { parts.append(ranCommands(ran).lowercasedFirst(if: !parts.isEmpty)) }
            var text = parts.isEmpty ? nothingRemoved : parts.joined(separator: " and ")
            if skipped > 0 { text += ". \(skipped) skipped." }
            if problems > 0 { text += (skipped > 0 ? " " : ". ") + (problems == 1 ? "1 had a problem." : "\(problems) had a problem.") }
            return text
        }
    }
}

private extension String {
    func lowercasedFirst(if condition: Bool) -> String {
        guard condition, let first else { return self }
        return first.lowercased() + dropFirst()
    }
}

extension Copy {
    /// External drives (plan 7).
    public enum Drives {
        public static let sidebarGroup = "Drives"
        public static func scan(_ name: String) -> String { "Scan \(name)" }
        public static func notConnected(_ name: String) -> String { "\(name) isn't connected" }
        public static let trashTitle = "Trash on this drive"
        public static let trashDetail = "Files trashed from this drive stay on it until the Trash is emptied."
        public static let trashHandoff = "Open the Trash"
        public static let trashAfterwards = "Items keep using space until they are permanently deleted."
        public static let trashHowRemoved = "Review individual items in Tools → Trash Bins or open Trash in Finder."
        public static let spotlightTitle = "Spotlight index"
        public static let spotlightDetail = "macOS keeps a search index of this drive here, so Spotlight can find its files."
        public static let spotlightAfterwards = "macOS manages it and rebuilds it when it needs to."
        public static let spotlightHowRemoved = "Leave it. macOS manages it."
        public static let fseventsDetail = "macOS keeps a log of file changes on this drive here. Time Machine and other apps use it."
        public static let fseventsAfterwards = "macOS trims it on its own."
        public static let fseventsHowRemoved = "Leave it. macOS manages it."
        public static let versionsDetail = "macOS keeps earlier versions of documents edited on this drive here."
        public static let versionsAfterwards = "macOS removes old versions on its own."
        public static let versionsHowRemoved = "Leave it. macOS manages it."
        public static let backupsDetail = "Time Machine keeps its backups here."
        public static let backupsAfterwards = "Manage them in Time Machine settings. Andromeda doesn't touch them."
        public static let backupsHowRemoved = "Time Machine manages them."
        public static let fseventsTitle = "File change log"
        public static let versionsTitle = "Document versions"
        public static let backupsTitle = "Time Machine backups"
        public static let notMeasured = "Not measured: macOS keeps this folder private"
        public static let topLevelGroupsOnly = "At the top of this drive, only files in ticked groups move. Everything else stays where it is."
        public static let readOnlyNote = "This drive is read-only. Andromeda can show what's on it but can't organize it."
        public static let organizeFormatNote =
            "Andromeda can scan this drive. Its format doesn't support the moves that Andromeda can safely undo."
        public static let timeMachineNote = "This is a Time Machine backup disk. Andromeda only shows its size."
        public static let diskImage = "Disk image"
        public static let timeMachineDisk = "Time Machine backup disk"
        public static func otherFiles(_ size: String) -> String { "Other files: \(size)" }
        public static func disconnected(_ name: String) -> String { "\(name) was disconnected" }
        /// A drive that isn't connected: when Andromeda last saw it mounted (decision 4). A short time like the
        /// masthead's "Scanned at".
        public static func lastSeen(_ date: Date) -> String {
            Calendar.current.isDateInToday(date)
                ? "Last seen at \(date.formatted(date: .omitted, time: .shortened))"
                : "Last seen \(date.formatted(date: .abbreviated, time: .shortened))"
        }
        /// Other volumes in the same APFS container that are mounted right now.
        public static func sharesSpace(_ names: [String]) -> String {
            let list = names.count <= 1
                ? names.joined()
                : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
            let verb = names.count == 1 ? "is" : "are"
            return "\(list) \(verb) also mounted in this APFS container."
        }
        public static let insideHomeNote =
            "This drive is mounted inside your home folder, so Andromeda doesn't organize it."
        /// An undo row whose drive isn't connected: nothing was touched (plan 7 Task 6).
        public static let driveNotConnected = "Its drive isn't connected — left alone."
        /// Move to… from a folder on a drive into a folder off it (`DestinationGuard`, plan 7 Task 7).
        public static let outsideDrive = DestinationGuard.outsideDriveText
        /// Settings › Rules: the drive a rule was made on, mounted or not (plan 7 Task 7).
        public static func ruleOnDrive(_ name: String) -> String { "On \(name)" }
        public static let ruleOnMissingDrive = "On a drive that isn't connected"
        /// A drive rule's scope at the drive's top level.
        public static let ruleScopeDriveTop = "Only at the top of the drive"
    }

    public enum App {
        public static let relaunch = "Quit and reopen Andromeda so it can read everything."
        /// v1 §8 rev 4: on macOS 27 the access check posts a one-time system notice until access is granted.
        public static let blockedNotice =
            "Until you allow access, macOS may show “Data Access Blocked” for Andromeda once. That's expected: Andromeda checks for access by trying to read one protected folder, and nothing was read."
        public static let fallbackSteps =
            "Open System Settings, choose Privacy & Security, then Full Disk Access, and turn on Andromeda."
        public static let scanFailed =
            "The scan couldn't finish. Try again, and if it keeps happening, export a report and ask for help."
    }
}

extension Copy {
    /// Organize copy. Task 11 and later extend this namespace.
    public enum Organize {
        public static let settingsTitle = "Organize"
        public static let settingsSubtitle = "When Andromeda suggests offloading or moving your files."
        public static let offloadSize = "Offload files bigger than"
        public static let offloadAge = "Offload files not used for"
        public static let moveSize = "Move files bigger than"
        public static let moveAge = "Move files not used for"
        public static let destinationsHeading = "Where files go"
        public static let noCloudFolders = "No cloud folders found on this Mac."
        public static func megabytes(_ n: Int) -> String { "\(n) MB" }
        public static func days(_ n: Int) -> String { n == 1 ? "1 day" : "\(n) days" }

        // Offload (Task 11). Hand-off only: Andromeda never evicts (decision 19a).
        public static func rowNote(provider: CloudProvider) -> String {
            "The file stays in \(provider.displayName) and in Finder. Opening it downloads it again, which needs the internet."
        }

        /// Finder's own wording per provider, read on the Air (macOS 26, Task 20 T5): iCloud Drive and Google Drive
        /// show the system "Remove Download"; Dropbox hides it and offers its own "Make online-only"; OneDrive
        /// offers "Free Up Space".
        public static func handOff(for provider: CloudProvider) -> String {
            switch provider {
            case .oneDrive: "In Finder, right-click → Free Up Space."
            case .dropbox: "In Finder, right-click → Make online-only."
            case .iCloudDrive, .googleDrive: "In Finder, right-click → Remove Download."
            }
        }

        /// Badge text for rows that aren't a plain hand-off; nil for `.handOff`.
        public static func statusText(_ status: RowStatus) -> String? {
            switch status {
            case .handOff: nil
            case .keepsOwnCopy: "The cloud app keeps its own copy"
            case .stillSyncing, .conflict: "Still syncing"
            }
        }

        // Cloud view (Task 12). No "freed" claim anywhere: after Check again the total is just recomputed.
        public static let cloudTitle = "Make Cloud Files Online-Only"
        public static let cloudSubtitle =
            "Find files already in the cloud that still use space on this Mac. Andromeda shows them in Finder, where you can remove the downloaded copies."
        public static func checkProvider(_ provider: CloudProvider) -> String { "Check \(provider.displayName)" }
        /// Cloud view, iCloud Drive without Full Disk Access: its folder is protected, so it isn't checked.
        public static let iCloudNeedsAccess =
            "Andromeda needs Full Disk Access to check iCloud Drive. Its folder is protected, so Andromeda doesn't look inside it until you turn access on."
        public static func uncheckedNote(_ provider: CloudProvider) -> String {
            "Andromeda looks inside \(provider.displayName) only when you ask. macOS may ask you to allow it."
        }
        public static func sectionTitle(_ provider: CloudProvider, account: String?) -> String {
            account.map { "\(provider.displayName) (\($0))" } ?? provider.displayName
        }
        public static let checking = "Checking…"
        public static let stopChecking = "Stop"
        public static let checkAgain = "Check again"
        public static let showInFinder = "Show in Finder"
        public static let nothingToSuggest = "Nothing here is large and unused for long enough to suggest."
        public static func total(_ size: String) -> String { "Could free at least \(size)" }
        public static func frees(_ size: String) -> String { "frees at least \(size)" }
        public static let freesUnknown = "space it frees can't be measured"
        public static func folderRow(_ name: String, items: Int) -> String { "\(name) · \(items) items" }
        public static func lastUse(_ use: LastUse) -> String {
            let date = use.date.formatted(.dateTime.month(.abbreviated).year())
            return use.kind == .changed ? "Last changed \(date)" : "Last opened \(date)"
        }
        /// The Storage overview's own row (ruling P8), separate from the quick wins.
        public static let couldBeOnlineOnlyTitle = "Could be online-only"
        public static func couldBeOnlineOnly(_ size: String) -> String {
            "Could be online-only: frees at least \(size) in the cloud folders you've checked"
        }

        // Move to cloud (Task 14).
        public static let moveToCloudTitle = "Move to Cloud"
        public static let moveToCloudSubtitle =
            "Move files from this Mac into a cloud folder you choose. Review the suggested files before moving them."
        public static let destinationLabel = "Move to"
        public static let finding = "Finding large files you haven't used in a while…"
        public static let findAgain = "Look again"
        public static func notSuggested(_ name: String) -> String {
            "\(name) isn't suggested here: it was used recently, is smaller than your Move setting, or Andromeda doesn't move it."
        }

        public static func belowMoveMinimum(_ name: String, minimum: String) -> String {
            "The scan measured \(name) below your \(minimum) minimum for cloud suggestions. You can change the minimum in Settings › Organize."
        }

        // Review sheet (§4.1 step 3).
        public static func uploadWarning(_ provider: CloudProvider) -> String {
            "These will upload to \(provider.displayName). Check you have room in your plan."
        }
        public static let stillUsesSpace =
            "These files can still use space after uploading. To reclaim local space, make the uploaded files online-only in Finder."
        /// "Move \(n) items to \(provider)"; one item reads "1 item".
        public static func confirmMove(_ n: Int, provider: CloudProvider) -> String {
            "Move \(n) \(n == 1 ? "item" : "items") to \(provider.displayName)"
        }
        public static func confirmMove(_ n: Int) -> String { n == 1 ? "Move 1 item" : "Move \(n) items" }
        public static func couldntMove(_ message: String) -> String { "Couldn't move this: \(message)" }
        public static let reviewSubtitle = "Each item moves only when you confirm. Undo puts it back from History."
        public static func fromTo(_ from: String, _ to: String) -> String { "\(from) → \(to)" }
        public static let leftAloneHeading = "Left alone"
        public static let exportPlan = "Export plan"
        public static let exportText = "As text…"
        public static let exportJSON = "As JSON…"
        public static func planFileName(date: String, json: Bool) -> String { "Andromeda plan \(date).\(json ? "json" : "txt")" }
        public static let applying = "Moving"
        /// Apply and undo progress lines.
        public static func moving(_ done: Int, of total: Int) -> String { "Moving \(done) of \(total)" }
        public static func puttingBack(_ done: Int, of total: Int) -> String { "Putting back \(done) of \(total)" }

        // Receipt and History.
        public static func movedTo(_ provider: CloudProvider) -> String { "Moved to \(provider.displayName)" }
        public static let moved = "Moved"
        public static let folderCreated = "Folder created"
        public static let movedBack = "Moved back"
        /// A folder Andromeda made, sent to the Trash by undo (it was empty or held only `.DS_Store`).
        public static let folderTrashed = "Moved to the Trash (it was empty)"
        public static func receiptHeadline(moved: Int, provider: CloudProvider?, skipped: Int, problems: Int) -> String {
            let count = moved == 1 ? "1 item" : "\(moved) items"
            var text = moved == 0 ? "Nothing was moved"
                : provider.map { "Moved \(count) to \($0.displayName)" } ?? "Moved \(count)"
            if skipped > 0 { text += ". \(skipped) skipped." }
            if problems > 0 { text += (skipped > 0 ? " " : ". ") + (problems == 1 ? "1 had a problem." : "\(problems) had a problem.") }
            return text
        }
        public static let applyStopped =
            "Andromeda stopped because it couldn't write its record of moves. The items listed were handled; the rest weren't touched."
        public static let uploading = "Uploading"
        public static let uploadUnconfirmed = "Upload not yet confirmed"
        public static let uploadConflict = "Sync conflict"
        public static func uploadedLocally(_ provider: CloudProvider) -> String {
            "Uploaded to \(provider.displayName) · still on this Mac"
        }
        public static func onlineOnly(_ provider: CloudProvider) -> String { "Online-only in \(provider.displayName)" }
        /// History: nothing is at the moved item's destination any more. Claims nothing about where it went.
        public static func notInProvider(_ provider: CloudProvider) -> String { "Not in \(provider.displayName) any more" }
        /// Rev 2.4. `onlineOnly`: the item is online-only now, so moving it back downloads it.
        public static func undoNote(originalFolder: String, provider: CloudProvider, onlineOnly: Bool) -> String {
            let base = "Undo moves it back to \(originalFolder). This also removes it from \(provider.displayName)."
            return onlineOnly ? base + " It downloads again first, so you need to be online." : base
        }
        public static let interruptedLabel = "Interrupted"
        public static let interruptedNote =
            "Andromeda stopped during this run. It has checked where each item is now; Undo puts back only what it finds where it left it."
        public static let undoRun = "Undo this run"
        // After a run: hand its new group folders to Move to cloud (Organize 3b Task 9).
        public static let moveSomeToCloud = "Move some of these to the cloud…"
        public static let handOffTitle = "Move folders from this run to the cloud"
        public static let recommended = "Recommended"
        public static let handOffNote =
            "Only folders over 500 MB that you haven't used in a while are recommended. Moving a folder frees space only once it has uploaded and is made online-only."
        /// **Review** found nothing to plan (the chosen folders are gone or can't be read, or an apply started).
        public static let handOffNothing = "Nothing to move right now."
        public static let undoConfirmTitle = "Undo this run?"
        public static let undoConfirmBody =
            "Each item goes back only if it's still where Andromeda left it and its old place is free. Anything else is left alone."
        public static let undoConfirm = "Undo"
        public static let undoGroup = "Undo this group"
        public static func undoGroupConfirmTitle(_ name: String) -> String { "Undo “\(name)”?" }
        public static let undoGroupConfirmBody =
            "Its files go back where they were. The folder Andromeda made for them goes to the Trash if it's empty."
        /// A group row in the receipt and History: "Nietzsche, 4 files".
        /// F10: a group whose files are all back where they were.
        public static let groupUndone = "Put back"
        public static func groupRow(_ name: String, files: Int) -> String {
            "\(name), \(files) \(files == 1 ? "file" : "files")"
        }
        public static func undoGroupLabel(_ name: String) -> String { "Undo this group, \(name)" }
        /// Why one item couldn't be put back (an undo-time skip or failure).
        public static func undoReason(_ outcome: Outcome) -> String {
            switch outcome {
            case .skipped(.notWhereWeLeftIt): Receipt.notWhereWeLeftIt
            case .skipped(.originalPathOccupied): "Something is already at the original location — left alone."
            case .skipped(.originalParentMissing): "The original folder is gone — left alone."
            case .skipped(.notEmpty): "The folder isn't empty — left alone."
            case .skipped(.alreadyGone): Receipt.alreadyGone
            case .skipped(.destinationOccupied): "Andromeda can't tell it made this folder — left alone."
            case .skipped: "Couldn't be put back — left alone."
            case .failed(let message): "Couldn't be put back: \(message)"
            case .done, .restored, .permanentlyDeleted, .planned: ""
            }
        }
        public static func undoIncomplete(_ n: Int) -> String {
            n == 1 ? "1 item couldn't be put back. History shows why." : "\(n) items couldn't be put back. History shows why."
        }
        public static let undoStopped =
            "Andromeda couldn't finish the undo because it couldn't write its record. History shows what was put back."
        public static let automationBusyUndo =
            "Folder automation is still running. Try Undo again when it finishes."

        // Organize a folder (Organize 2, §6.1, boards 07–09).
        public static let organizeFolderTitle = "Organize a folder"
        public static let organizeFolderSubtitle =
            "Sorts one folder's files by kind and date, by their names and details only. Nothing moves until you apply the plan."
        public static let downloads = "Downloads"
        public static let desktop = "Desktop"
        public static let chooseFolder = "Choose…"
        public static let planning = "Making a plan…"
        public static let nowHeading = "Now"
        public static let proposedHeading = "Proposed"
        public static let unsorted = "Unsorted — needs you"
        public static let applyPlan = "Apply plan"
        public static let canTrashInStorage = FolderPlanner.canTrashInStorageText
        public static func organized(_ folder: String) -> String { "\(folder) is organized" }
        public static func folderReceiptHeadline(folder: String, moved: Int, skipped: Int, problems: Int) -> String {
            var text = moved == 0 ? "Nothing was moved" : organized(folder)
            if skipped > 0 { text += ". \(skipped) skipped." }
            if problems > 0 { text += (skipped > 0 ? " " : ". ") + (problems == 1 ? "1 had a problem." : "\(problems) had a problem.") }
            return text
        }
        public static func foldersToCreate(_ n: Int) -> String { n == 1 ? "1 folder to create" : "\(n) folders to create" }
        public static func filesToMove(_ n: Int) -> String { n == 1 ? "1 file to move" : "\(n) files to move" }
        public static func filesToRename(_ n: Int) -> String { n == 1 ? "1 file to rename" : "\(n) files to rename" }
        public static func leftForYou(_ n: Int) -> String { "\(n) left for you" }
        /// The same four counts as a tile's label under its number.
        public static func foldersToCreateLabel(_ n: Int) -> String { n == 1 ? "folder to create" : "folders to create" }
        public static func filesToMoveLabel(_ n: Int) -> String { n == 1 ? "file to move" : "files to move" }
        public static func filesToRenameLabel(_ n: Int) -> String { n == 1 ? "file to rename" : "files to rename" }
        public static let leftForYouLabel = "left for you"
        public static func treeFolder(_ path: String, count: Int) -> String {
            "\(path) · \(count == 1 ? "1 file" : "\(count) files")"
        }
        public static func renamedTo(_ name: String) -> String { "Renamed to \(name)" }
        public static let nothingToOrganize = "Nothing here to organize. Folders and hidden files stay where they are."
        public static let homeGroupsOnly = "In your home folder, only files in ticked groups move. Everything else stays where it is."
        public static let applySubtitle = "Each file moves only when you apply. Undo this run puts everything back."
        public static let namingHeading = "Rename files"
        public static let datePhotos = "Use the day for photos and screenshots"
        public static let leaveSensible = "Leave files that already match a sensible pattern"
        public static let tidySuffixes = "Tidy duplicates' suffixes"
        public static let readInside = "Read dates and names from inside PDFs and scans"
        public static let comingLater = "Coming later"

        // Organize 3a: groups (each becomes a new folder).
        public static let groupsTitle = "Groups"
        public static let sameName = "Same name"
        public static func sharesToken(_ t: String) -> String { "Shares “\(t)”" }
        public static let numberedSeries = "Numbered series"
        public static func madeWithin(_ m: Int) -> String { m == 1 ? "Made within a minute" : "Made within \(m) minutes" }
        public static let suggestion = "Suggestion"
        public static let notInThisGroup = "Not in this group"
        public static let keepTogether = "Keep together"
        public static let putInOneFolder = "Put these in one folder"
        public static let nameThisGroup = "Name this group"
        public static let sortRestByKind = "Sort the rest by kind"
        /// A rename or a parent folder whose name another group or parent already has.
        public static let nameInUse = "Another group already uses this name"
        public static let renameGroup = "Rename this group"
        public static let applySuggestion = "Apply"
        public static let showFiles = "Files in this group"
        /// The disclosure's accessible label.
        public static func filesIn(_ name: String) -> String { "Files in \(name)" }
        /// A group card's tick, for VoiceOver (the card itself carries `groupCardLabel`).
        public static func includeGroup(_ name: String) -> String { "Include \(name)" }
        /// The heading over Sort the rest by kind.
        public static let sortingHeading = "Sorting"
        /// A group edit asked for while a plan is being made or applied, or another review is open.
        public static let cantEditNow = "Wait until the current step finishes"
        public static let enterName = "Enter a name"
        public static let nameTooLong = "Use 100 characters or fewer"
        public static let nameBadCharacters = "Names can't contain / or :"
        public static let nameLeadingDot = "Names can't start with a dot"
        public static let nameIsKindFolder = "That name is used for sorting by kind"
        /// Why a group or parent folder name can't be used.
        public static func nameProblem(_ p: GroupRules.NameProblem) -> String {
            switch p {
            case .empty: enterName
            case .tooLong: nameTooLong
            case .badCharacters: nameBadCharacters
            case .leadingDot: nameLeadingDot
            case .kindName: nameIsKindFolder
            }
        }
        public static func parentSuggestionLine(_ name: String, groups: Int) -> String {
            "Put these \(groups) groups inside “\(name)”"
        }
        public static func groupCardLabel(_ name: String, ticked: Int, count: Int, suggestion: Bool = false) -> String {
            "\(name), \(ticked) of \(count) files" + (suggestion ? ", suggestion" : "")
        }
        public static func tickedOfCount(_ ticked: Int, _ count: Int) -> String { "\(ticked) of \(count)" }
        /// Why a group's files were put together, as its card says it.
        public static func reason(_ r: GroupReason) -> String {
            switch r {
            case .sameName: sameName
            case .sharesToken(let t): sharesToken(t)
            case .series: numberedSeries
            case .madeWithin(let m): madeWithin(m)
            case .intoYourFolder(let p): intoYourFolder(p)
            case .matchesYourFolder(let p): matchesYourFolder(p)
            case .rule(let p): yourRule(p)
            case .movedByYou: movedByYou
            }
        }
        /// Plan 6 (C1): a group placed by one of the user's saved rules (its pattern), and the Move to… group.
        public static func yourRule(_ p: String) -> String { "Your rule: “\(p)”" }
        public static let movedByYou = "Moved by you"
        /// A file a rule or Move to… sends into the folder it is already in (the planner's text).
        public static let alreadyThere = FolderPlanner.alreadyThereText
        /// Plan 6 (B): a group or file going into one of the user's own folders (a relative path).
        public static func intoYourFolder(_ p: String) -> String { "Goes into your folder “\(p)”" }
        public static func matchesYourFolder(_ p: String) -> String { "Matches your folder “\(p)”" }
        /// A loose file two or more of the user's folders match: listed under Left alone (the planner's text).
        public static func matchesYourFolders(_ paths: [String]) -> String { FolderPlanner.matchesYourFoldersText(paths) }
        /// The card's picker when more than one of the user's folders matches.
        /// (The brief's id `chooseFolder` is taken by the folder picker's "Choose…".)
        public static let chooseDestination = "Choose where this goes"
        public static let newFolderChoice = "A new folder"
        /// **Remember this** on a group two of the user's folders match, before one is chosen.
        public static let rememberUndecided = "Choose where this goes first"
        /// An `.inHome` rule whose folder no longer exists (the planner's text): its files wait in Unsorted.
        public static let ruleFolderGone = FolderPlanner.ruleFolderGoneText

        // Plan 6 Task 8: Move to…, Remember this and Settings › Rules.
        public static let moveTo = "Move to…"
        public static func moveToLabel(_ file: String) -> String { "\(moveTo), \(file)" }
        public static let rememberThis = "Remember this"
        public static func rememberThisLabel(_ group: String) -> String { "\(rememberThis), \(group)" }
        public static let rulesTitle = "Organize Rules"
        public static let rulesSubtitle = "These rules suggest destinations in \(organizeFolderTitle). You review and apply the plan. Choose Automation to watch folders and act on matching files automatically."
        public static let rulesEmpty = "To save a rule, choose \(rememberThis) when picking a destination."
        public static let rulesUnreadable = "Andromeda couldn't read your rules, so none are used. Nothing has been changed."
        public static let replaceRules = "Start over with no rules"
        public static let rulesNotSaved = "Andromeda couldn't save your rules. Nothing has been changed."
        public static let replaceRulesConfirmTitle = "Start over with no rules?"
        public static let replaceRulesConfirmBody = "Andromeda replaces your rules file with an empty one. Your files aren't changed."
        public static func ruleBlocked(_ why: String) -> String { "Not used this time: \(why)" }
        public static let deleteRule = "Delete rule"
        public static func deleteRuleLabel(_ pattern: String) -> String { "\(deleteRule), \(pattern)" }
        public static let editRule = "Edit rule"
        public static func editRuleLabel(_ pattern: String) -> String { "\(editRule), \(pattern)" }
        public static let saveRule = "Save rule"
        public static let rulePattern = "File names like"
        public static let ruleDestination = "Goes into"
        /// Before a home destination's folders in the rule editor.
        public static let ruleHomePrefix = "~/"
        public static let ruleScopeAny = "In any folder"
        public static func ruleScopeFolder(_ path: String) -> String { "Only in \(path)" }
        /// A rule destination below whichever folder is organized (a relative path).
        public static func ruleDestinationInFolder(_ path: String) -> String { "“\(path)” in the folder you organize" }
        /// Where a rule sends files, as Settings › Rules lists it: home-relative (`~/Documents/Reports`), or
        /// below the organized folder.
        /// On a drive (`onDrive`), `.inHome` folders are below the drive root and shown as that path.
        public static func ruleDestinationText(_ d: OrganizeRule.Destination, home: URL, onDrive: Bool = false) -> String {
            switch d {
            case .relative(let c): ruleDestinationInFolder(c.joined(separator: "/"))
            case .inHome(let c) where onDrive: c.joined(separator: "/")
            case .inHome(let c): Scan.displayPath(c.reduce(home) { $0.appendingPathComponent($1) }, home: home)
            }
        }
        public static func ruleScopeText(_ s: OrganizeRule.Scope, home: URL, onDrive: Bool = false) -> String {
            switch s {
            case .anyFolder: ruleScopeAny
            case .folder(let p) where onDrive: p.isEmpty ? Drives.ruleScopeDriveTop : ruleScopeFolder(p)
            case .folder(let p): ruleScopeFolder(Scan.displayPath(home.appendingPathComponent(p), home: home))
            }
        }
        /// The destination guard's texts (`DestinationGuard`), forwarded so the app reads only `Copy`.
        public static let onAnotherDisk = DestinationGuard.otherDiskText
        public static let cantReadFolder = DestinationGuard.unreadableText
        /// Why Organize leaves a place alone (`OrganizeGuard`), as a Move to… refusal says it.
        public static func excluded(_ e: Exclusion) -> String { OrganizeGuard.reasonText(e) }
        /// Why a rule can't be saved or used: a bad folder name says which, as renaming a group does;
        /// the rest are `RuleValidator`'s texts.
        public static func ruleProblem(_ p: RuleProblem) -> String {
            if case .badFolderName(let name) = p { return nameProblem(name) }
            return RuleValidator.problemText(p)
        }

        public static func bucketHeader(_ bucket: AgeBucket, kind: LastUse.Kind) -> String {
            let verb = kind == .changed ? "changed" : "opened"
            switch bucket {
            case .overAYear: return "Not \(verb) in over a year"
            case .sixToTwelveMonths: return "Not \(verb) in 6–12 months"
            }
        }
    }
}
