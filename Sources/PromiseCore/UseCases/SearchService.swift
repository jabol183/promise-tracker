import Foundation

/// Offline keyword search across titles, details, notes, tags, people and the original
/// words; case- and diacritic-insensitive (FR-07).
public struct SearchQuery: Equatable, Sendable {
    public var text: String
    public var statuses: Set<CommitmentStatus>?
    public var dueFrom: Date?
    public var dueTo: Date?
    public var personId: UUID?

    public init(text: String = "", statuses: Set<CommitmentStatus>? = nil, dueFrom: Date? = nil, dueTo: Date? = nil, personId: UUID? = nil) {
        self.text = text
        self.statuses = statuses
        self.dueFrom = dueFrom
        self.dueTo = dueTo
        self.personId = personId
    }
}

public struct SearchService: Sendable {
    public init() {}

    public func search(_ query: SearchQuery, commitments: [Commitment], people: [Person]) -> [Commitment] {
        let peopleById = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) })
        let terms = TextNormalizer.tokens(query.text)
        return commitments.filter { c in
            if let s = query.statuses, !s.contains(c.status) { return false }
            if let pid = query.personId, c.personId != pid { return false }
            if let from = query.dueFrom { guard let due = c.dueAt, due >= from else { return false } }
            if let to = query.dueTo { guard let due = c.dueAt, due <= to else { return false } }
            guard !terms.isEmpty else { return true }
            var haystack = [c.title, c.details, c.notes, c.context, c.originalInput, c.waitingOnText, c.nextAction]
                .compactMap { $0 }
            haystack += c.tags
            if let p = c.personId.flatMap({ peopleById[$0] }) { haystack.append(p.displayName); haystack += p.aliases }
            let tokens = Set(haystack.flatMap(TextNormalizer.tokens))
            // Every term must prefix-match some token ("prop" finds "proposal").
            return terms.allSatisfy { term in tokens.contains { $0.hasPrefix(term) } }
        }
    }
}
