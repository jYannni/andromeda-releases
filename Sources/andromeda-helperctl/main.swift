// Dev harness for the privileged helper. Run only from a signed harness bundle on a test Mac
// (scripts/build-helper-harness.sh); `register` installs a root launch daemon.
import Foundation
import ServiceManagement
import AndromedaHelperClient
import AndromedaHelperProtocol

func statusName(_ s: SMAppService.Status) -> String {
    switch s {
    case .notRegistered: "notRegistered"
    case .enabled: "enabled"
    case .requiresApproval: "requiresApproval"
    case .notFound: "notFound"
    @unknown default: "unknown"
    }
}

func describe(_ error: Error) -> String {
    if let e = error as? HelperClientError {
        switch e {
        case .rejected(let code): return "\(code.rawValue)"
        default: return "\(e)"
        }
    }
    return "\(error)"
}

func fail(_ message: String) -> Never {
    print(message)
    exit(1)
}

let usage = "usage: andromeda-helperctl status|register|unregister|version|probe|measure <entryID>...|spotlight|requirements"
let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail(usage) }

// Exact argument count per subcommand (the command itself included). Extra arguments are rejected
// so that e.g. `register --dry-run` can never register.
// `measure` alone takes 1-4 IDs (read-only), so the Air gate can time back-to-back measures on
// one connection.
let arity: [String: ClosedRange<Int>] = [
    "status": 1...1, "register": 1...1, "unregister": 1...1, "version": 1...1, "probe": 1...1,
    "measure": 2...5, "spotlight": 1...1, "requirements": 1...1,
]
guard let allowed = arity[command], allowed.contains(args.count) else { fail(usage) }

// Read-only: prints the compiled-in requirement strings; touches no registration or connection.
if command == "requirements" {
    print(HelperIdentity.clientRequirement)
    print(HelperIdentity.helperRequirement)
    exit(0)
}

let registration = LiveHelperRegistration()
let client = HelperClient(registration: registration)

do {
    switch command {
    case "status":
        // Raw first: on macOS 27 a never-registered daemon reads notFound, which the app maps to notRegistered.
        print("\(statusName(registration.rawStatus)) (app sees \(statusName(registration.status)))")
    case "register":
        try registration.register()
        print(statusName(registration.status))
    case "unregister":
        try await registration.unregister()
        print(statusName(registration.status))
    case "version":
        print(try await client.version())
    case "probe":
        // Task 7 Step 5: skips this bundle's own SMAppService status, so a negative-test copy
        // (ad-hoc, DevSigned.app, OtherID.app) really connects and meets the helper's check.
        print("ok \(try await client.probeVersion())")
    case "measure":
        for id in args.dropFirst() {
            let start = Date()
            let r = try await client.measure(entryID: id)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            let priv = r.privateBytes.map(String.init) ?? "nil"
            print("entryID=\(r.entryID) bytes=\(r.bytes) privateBytes=\(priv) clonesPresent=\(r.clonesPresent) "
                + "unreadable=\(r.unreadableCount) skipped=\(r.skippedCount) truncated=\(r.truncated) "
                + "paths=\(r.measuredPaths.joined(separator: ",")) ms=\(ms)")
        }
    case "spotlight":
        try await client.rebuildSpotlightIndex()
        print("ok")
    default:
        fail(usage)
    }
} catch {
    fail("error: \(describe(error))")
}
