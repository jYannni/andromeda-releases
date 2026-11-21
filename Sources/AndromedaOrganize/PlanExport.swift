import Foundation

/// Plain-text and JSON renderings of a plan, for "Copy plan" and "Export".
public enum PlanExport {
    /// Step id → name of the group the step belongs to.
    private static func groupNames(_ groups: [PlanGroup]) -> [UUID: String] {
        var names: [UUID: String] = [:]
        for g in groups { for id in g.stepIDs { names[id] = g.name } }
        return names
    }

    public static func text(_ p: OrganizePlan, groups: [PlanGroup] = []) -> String {
        let names = groupNames(groups)
        var lines: [String] = p.steps.map { step in
            switch step.action {
            case .createFolder(let url): return "folder  \(url.path)"
            case .copy(let from, let to): return "copy  \(from.path)  →  \(to.path)"
            case .move(let from, let to):
                let tag = names[step.id].map { "  [\($0)]" } ?? ""
                return "move  \(from.path)  →  \(to.path)\(tag)"
            }
        }
        if !p.leftAlone.isEmpty {
            lines.append("")
            lines.append("Left alone")
            lines += p.leftAlone.map { "\($0.url.path) — \($0.reason)" }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private struct Doc: Encodable {
        struct Step: Encodable {
            let action: String
            let from: String?
            let to: String
            let bytes: Int64
            let group: String?
        }
        struct Group: Encodable {
            let id: String
            let name: String
            let parent: String?
            let steps: Int
            let reasons: [String]
            /// A rule group's destination folder.
            let destination: String?
        }
        struct Left: Encodable {
            let path: String
            let reason: String
        }
        let planID: String
        let title: String
        let steps: [Step]
        let leftAlone: [Left]
        let groups: [Group]?
    }

    /// A group reason as the JSON export writes it: `"sameName"`, `"sharesToken:<word>"`, `"rule:<pattern>"`, ….
    public static func reasonToken(_ r: GroupReason) -> String {
        switch r {
        case .sameName: "sameName"
        case .sharesToken(let t): "sharesToken:" + t
        case .series: "series"
        case .madeWithin(let m): "madeWithin:\(m)"
        case .intoYourFolder(let p): "intoYourFolder:" + p
        case .matchesYourFolder(let p): "matchesYourFolder:" + p
        case .rule(let p): "rule:" + p
        case .movedByYou: "movedByYou"
        }
    }

    public static func json(_ p: OrganizePlan, groups: [PlanGroup] = []) throws -> Data {
        let names = groupNames(groups)
        let steps = p.steps.map { step -> Doc.Step in
            switch step.action {
            case .createFolder(let url):
                Doc.Step(action: "createFolder", from: nil, to: url.path, bytes: 0, group: nil)
            case .copy(let from, let to):
                Doc.Step(action: "copy", from: from.path, to: to.path, bytes: step.snapshot?.bytes ?? 0, group: nil)
            case .move(let from, let to):
                Doc.Step(action: "move", from: from.path, to: to.path, bytes: step.snapshot?.bytes ?? 0,
                         group: names[step.id])
            }
        }
        // A group's steps as the file lists them; a group with none in this plan (all unticked) is left out.
        let inPlan = Set(p.steps.map(\.id))
        let exported: [Doc.Group] = groups.compactMap { g in
            let n = g.stepIDs.filter(inPlan.contains).count
            return n == 0 ? nil : .init(
                id: g.id, name: g.name, parent: g.parent, steps: n, reasons: g.reasons.map(reasonToken),
                destination: g.destination?.path)
        }
        let doc = Doc(
            planID: p.planID.uuidString, title: p.title, steps: steps,
            leftAlone: p.leftAlone.map { .init(path: $0.url.path, reason: $0.reason) },
            groups: exported.isEmpty ? nil : exported)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(doc)
    }
}
