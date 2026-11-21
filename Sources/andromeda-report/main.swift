import AndromedaCore
import Foundation

// Read-only: scans and prints. Nothing here removes, trashes or plans removal.

func printErr(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

let args = Array(CommandLine.arguments.dropFirst())
guard args.isEmpty || args == ["--json"] else {
    printErr("usage: andromeda-report [--json]")
    exit(2)
}
let asJSON = !args.isEmpty

let env = ScanEnvironment.live()
let catalog: [CatalogEntry]
do {
    catalog = try BundledCatalog.load()
} catch {
    printErr("andromeda-report: can't load the catalog: \(error)")
    exit(1)
}

let sizer = AllocatedSizer()
let findings = CatalogScanner(env: env, snapshots: LiveSnapshotLister(), sizer: sizer).scan(catalog)
let catalogClaimed = findings.flatMap { $0.items.map(\.url) }
// ~/Applications is inside home; the applications scan owns it.
let large = LargeItemsScanner(env: env, sizer: sizer).scan(excluding: catalogClaimed + env.applicationsRoots)
let apps = ApplicationsScanner(roots: env.applicationsRoots, sizer: sizer).scan(excluding: catalogClaimed, control: nil)

// After the other walks, like the app: skips what they claimed. No helper here, so other accounts stay unmeasured.
let outside = OutsideHomeScanner(env: env, sizer: sizer)
    .scan(skipping: OutsideHomeScanner.claims(catalogItems: catalogClaimed, env: env), control: nil)

var usedKnown = true
let usage: VolumeUsage
do {
    usage = try LiveVolumeUsageProvider().current()
} catch {
    printErr("andromeda-report: couldn't read disk usage (\(error)); continuing without it.")
    usedKnown = false
    usage = VolumeUsage(containerCapacity: 0, containerFree: 0, dataVolumeUsed: 0, purgeable: .notMeasurable)
}

let fda = FullDiskAccessProbe.check(env: env)
// nil when the local directory couldn't be listed; the report then says so.
let accounts = OtherAccounts.list(env: env)
let reconciliation = Reconciler.reconcile(
    usage: usage, findings: findings, largeItems: large.items,
    unlisted: large.unlisted, applications: apps.total,
    unlistedClones: large.unlistedClones, applicationsClones: apps.clonesPresent, unreadable: large.unreadable + apps.unreadable, fda: fda,
    outside: outside,
    otherAccounts: (accounts ?? []).map {
        OtherAccountSize(uid: $0.uid, name: $0.name, bytes: nil, atLeast: false)
    },
    helperOn: false, accountsKnown: accounts != nil)
let report = ReportExporter.make(
    env: env, usage: usage, findings: findings, largeItems: large.items,
    reconciliation: reconciliation, fda: fda, usedKnown: usedKnown, applications: apps.items)

do {
    if asJSON {
        FileHandle.standardOutput.write(try ReportExporter.json(report))
        FileHandle.standardOutput.write(Data("\n".utf8))
    } else {
        FileHandle.standardOutput.write(Data(ReportExporter.text(report).utf8))
    }
} catch {
    printErr("andromeda-report: \(error)")
    exit(1)
}
