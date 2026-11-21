import Foundation
import Security

/// Identities and code-signing requirements shared by the app and the helper.
/// This is the only file that may contain a code-signing requirement string.
public enum HelperIdentity {
    public static let appBundleID = "io.github.jyannni.diskplain"
    /// Also the launchd label and the Mach service name.
    public static let helperBundleID = "io.github.jyannni.diskplain.helper"
    public static let automationWorkerBundleID = "io.github.jyannni.diskplain.automation"
    public static let plistName = "io.github.jyannni.diskplain.helper.plist"
    public static let teamID = "6K3XJ2VR2C"
    public static let version = HelperBuildInfo.version

    /// Checked by the helper against the connecting app.
    public static var clientRequirement: String { requirement(identifier: appBundleID) }
    /// Checked by the app against the helper it connects to.
    public static var helperRequirement: String { requirement(identifier: helperBundleID) }
    public static func makeAppRequirement() -> SecRequirement? { compile(clientRequirement) }
    public static func makeAutomationWorkerRequirement() -> SecRequirement? {
        compile(requirement(identifier: automationWorkerBundleID))
    }

    private static func compile(_ text: String) -> SecRequirement? {
        var compiled: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &compiled) == errSecSuccess else { return nil }
        return compiled
    }

    private static func requirement(identifier: String) -> String {
        "anchor apple generic"
            + " and certificate 1[field.1.2.840.113635.100.6.2.6]"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13]"
            + " and certificate leaf[subject.OU] = \"\(teamID)\""
            + " and identifier \"\(identifier)\""
    }
}
