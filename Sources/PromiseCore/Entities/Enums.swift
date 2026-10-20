import Foundation

public enum CommitmentStatus: String, Codable, CaseIterable, Sendable {
    case draft, open, waiting, completed, cancelled, archived

    /// Statuses that still represent something the user owes someone.
    public var isActive: Bool { self == .open || self == .waiting }

    /// Statuses that are finished and live in History.
    public var isClosed: Bool { self == .completed || self == .cancelled }

    public func canTransition(to next: CommitmentStatus) -> Bool {
        if next == self { return true } // idempotent no-op
        switch (self, next) {
        case (.draft, .open), (.draft, .waiting), (.draft, .cancelled):
            return true
        case (.open, .waiting), (.open, .completed), (.open, .cancelled), (.open, .archived):
            return true
        case (.waiting, .open), (.waiting, .completed), (.waiting, .cancelled), (.waiting, .archived):
            return true
        case (.completed, .open), (.completed, .archived):
            return true
        case (.cancelled, .open), (.cancelled, .archived):
            return true
        case (.archived, .open):
            return true
        default:
            return false
        }
    }
}

public enum SourceType: String, Codable, CaseIterable, Sendable {
    case voice, text, siri
    case shareSheet = "share-sheet"
    case shortcut, `import`, manual
}

/// How precise the agreed deadline is. Kept separate from `dueAt` so the app never
/// pretends an approximate period ("next week") is a hard timestamp.
public enum DuePrecision: String, Codable, CaseIterable, Sendable {
    case none
    case day
    case datetime
    case approximate
    case relative
    case eventLinked = "event-linked"

    /// Only day and datetime deadlines can become overdue.
    public var isHardDeadline: Bool { self == .day || self == .datetime }
}

public enum Priority: String, Codable, CaseIterable, Sendable {
    case low, normal, high
}

public enum ReminderKind: String, Codable, CaseIterable, Sendable {
    case preDue = "pre-due"
    case due
    case overdue
    case dailyDigest = "daily-digest"
    case waitingCheckin = "waiting-checkin"
    /// Check-in for approximate periods ("next week"); never presented as a deadline.
    case approximateCheckin = "approximate-checkin"
    case snooze
    case custom
}

public enum ActivityEventType: String, Codable, CaseIterable, Sendable {
    case created, edited, rescheduled, reminded, snoozed
    case statusChanged = "status_changed"
    case completed, reopened
    case personLinked = "person_linked"
    case followupDrafted = "followup_drafted"
    case exported, deleted
}
