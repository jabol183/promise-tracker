import Foundation

/// Append-only history entry. Explains why a reminder fired or when a date changed.
public struct ActivityEvent: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var commitmentId: UUID
    public var eventType: ActivityEventType
    public var occurredAt: Date
    public var source: SourceType
    /// Small, display-oriented key/value payload (e.g. "from"/"to" for reschedules).
    public var payload: [String: String]

    public init(id: UUID = UUID(), commitmentId: UUID, eventType: ActivityEventType, occurredAt: Date,
                source: SourceType, payload: [String: String] = [:]) {
        self.id = id
        self.commitmentId = commitmentId
        self.eventType = eventType
        self.occurredAt = occurredAt
        self.source = source
        self.payload = payload
    }
}

/// A reminder the app wants the OS to deliver. Derived from commitment state; the
/// notification queue is never the source of truth.
public struct ReminderRule: Codable, Hashable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable { case planned, delivered, superseded, cancelled }

    /// Stable identifier derived from commitment id, kind and revision so that
    /// reconciliation can diff desired vs. pending notifications.
    public var id: String
    public var commitmentId: UUID?
    public var kind: ReminderKind
    public var scheduledAt: Date
    public var state: State
    public var revision: Int
    public var title: String
    public var body: String
    public var lastDeliveredAt: Date?
    public var snoozeCount: Int
    public var supersededBy: String?

    public init(id: String, commitmentId: UUID?, kind: ReminderKind, scheduledAt: Date, revision: Int,
                title: String, body: String, snoozeCount: Int = 0) {
        self.id = id
        self.commitmentId = commitmentId
        self.kind = kind
        self.scheduledAt = scheduledAt
        self.state = .planned
        self.revision = revision
        self.title = title
        self.body = body
        self.lastDeliveredAt = nil
        self.snoozeCount = snoozeCount
        self.supersededBy = nil
    }
}
