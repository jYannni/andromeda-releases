public struct ExplainerCard: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let body: String
    public let whatYouCanDo: String
}

extension ExplainerCard {
    static let purgeable = ExplainerCard(
        id: "purgeable", title: Copy.Cards.purgeableTitle, body: Copy.Cards.purgeableBody,
        whatYouCanDo: Copy.Cards.purgeableDo)
    static let appleIntelligence = ExplainerCard(
        id: "apple-intelligence", title: Copy.Cards.appleIntelligenceTitle,
        body: Copy.Cards.appleIntelligenceBody, whatYouCanDo: Copy.Cards.appleIntelligenceDo)
    static let orphanedRuntimes = ExplainerCard(
        id: "orphaned-runtimes", title: Copy.Cards.orphanedRuntimesTitle,
        body: Copy.Cards.orphanedRuntimesBody, whatYouCanDo: Copy.Cards.orphanedRuntimesDo)
    static let pendingUpdate = ExplainerCard(
        id: "pending-update", title: Copy.Cards.pendingUpdateTitle, body: Copy.Cards.pendingUpdateBody,
        whatYouCanDo: Copy.Cards.pendingUpdateDo)
}
