import Foundation

public struct Person: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var displayName: String
    public var normalizedName: String
    public var aliases: [String]
    public var notes: String?
    public var createdAt: Date
    public var isArchived: Bool
    /// Set only after Contacts permission and explicit linking (P1).
    public var contactIdentifier: String?
    /// Optional, user-entered contact channels (no Contacts permission needed).
    public var phone: String?
    public var email: String?
    /// Short relationship label, e.g. "Client · Chen Creative".
    public var relationship: String?
    /// Set when this person was merged into another; the record is kept so history
    /// still displays meaningfully.
    public var mergedIntoId: UUID?

    public init(id: UUID = UUID(), displayName: String, aliases: [String] = [], notes: String? = nil,
                createdAt: Date, contactIdentifier: String? = nil) {
        self.id = id
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.normalizedName = TextNormalizer.normalize(displayName)
        self.aliases = aliases
        self.notes = notes
        self.createdAt = createdAt
        self.isArchived = false
        self.contactIdentifier = contactIdentifier
        self.mergedIntoId = nil
    }

    public var initials: String {
        let parts = displayName.split(whereSeparator: { $0.isWhitespace }).prefix(2)
        let letters = parts.compactMap { $0.first.map(String.init) }.joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    /// All normalized names this person answers to.
    public var searchableNames: [String] {
        [normalizedName] + aliases.map(TextNormalizer.normalize)
    }
}
