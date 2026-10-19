import Foundation

/// How a spoken name relates to stored people. Never merges or picks silently
/// between candidates (PRD §4.2, edge case 6).
public enum PersonMatch: Codable, Hashable, Sendable {
    /// No name was mentioned.
    case none
    /// Exact name or alias match.
    case matched(UUID)
    /// One partial match (e.g. "Anna" → "Anna Kowalska"); preselected but highlighted.
    case suggested(UUID)
    /// Several people could match; the user must choose.
    case ambiguous([UUID])
    /// No stored person; saving will create one with this name.
    case new(String)

    public var resolvedPersonId: UUID? {
        switch self {
        case let .matched(id), let .suggested(id): return id
        default: return nil
        }
    }

    public var needsReview: Bool {
        switch self {
        case .ambiguous, .suggested: return true
        default: return false
        }
    }
}

public struct PersonMatcher: Sendable {
    public init() {}

    public func match(name: String?, in people: [Person]) -> PersonMatch {
        guard let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return .none }
        let n = TextNormalizer.normalize(name)
        let candidates = people.filter { !$0.isArchived && $0.mergedIntoId == nil }

        let exact = candidates.filter { $0.searchableNames.contains(n) }
        if exact.count == 1 { return .matched(exact[0].id) }
        if exact.count > 1 { return .ambiguous(exact.map(\.id)) }

        // First-name or first-token match: "Anna" vs "Anna Kowalska".
        let partial = candidates.filter { person in
            person.searchableNames.contains { stored in
                let storedTokens = stored.split(separator: " ").map(String.init)
                let spokenTokens = n.split(separator: " ").map(String.init)
                return storedTokens.first == spokenTokens.first && (storedTokens.count == 1 || spokenTokens.count == 1)
            }
        }
        if partial.count == 1 { return .suggested(partial[0].id) }
        if partial.count > 1 { return .ambiguous(partial.map(\.id)) }
        return .new(name.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// People whose names look alike — offered as merge *suggestions* only.
    public func mergeSuggestions(in people: [Person]) -> [(Person, Person)] {
        let active = people.filter { !$0.isArchived && $0.mergedIntoId == nil }
        var result: [(Person, Person)] = []
        for i in active.indices {
            for j in active.indices where j > i {
                let a = active[i], b = active[j]
                if a.normalizedName == b.normalizedName || Set(a.searchableNames).intersection(b.searchableNames).isEmpty == false {
                    result.append((a, b))
                } else if levenshtein(a.normalizedName, b.normalizedName) == 1 && min(a.normalizedName.count, b.normalizedName.count) >= 4 {
                    result.append((a, b))
                }
            }
        }
        return result
    }

    func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }
}
