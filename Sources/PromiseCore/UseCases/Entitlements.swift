import Foundation

/// Free vs. Pro limits (PRD §11). Closing, editing, exporting and deleting are never
/// gated; only creation beyond the free limits and premium extras are.
public struct EntitlementPolicy: Equatable, Sendable {
    public static let freeActiveCommitmentLimit = 15
    public static let freePeopleLimit = 10

    public var isPro: Bool
    public init(isPro: Bool) { self.isPro = isPro }

    public func canCreateCommitment(activeCount: Int) -> Bool {
        isPro || activeCount < Self.freeActiveCommitmentLimit
    }

    public func canCreatePerson(count: Int) -> Bool {
        isPro || count < Self.freePeopleLimit
    }

    public var advancedReminders: Bool { isPro }
    public var briefings: Bool { isPro }
    public var unlimitedFollowUpDrafts: Bool { isPro }
    public static let freeFollowUpDraftsPerWeek = 3

    public var commitmentLimitMessage: String {
        "The free plan holds \(Self.freeActiveCommitmentLimit) open promises. Complete one or upgrade to Pro to add more. Your existing promises stay fully usable."
    }

    public var peopleLimitMessage: String {
        "The free plan holds \(Self.freePeopleLimit) people. Upgrade to Pro for unlimited people, or link this promise to someone you already have."
    }
}
