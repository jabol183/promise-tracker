import Foundation

/// A promise the user made to someone (or to themselves). The person receiving the
/// promise, the expected outcome and the follow-through are first-class fields.
public struct Commitment: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    /// Original dictated/typed words; kept unless the user deletes them.
    public var originalInput: String
    public var status: CommitmentStatus
    public var createdAt: Date
    public var updatedAt: Date
    public var sourceType: SourceType
    public var owner: String
    public var personId: UUID?

    // MARK: Deadline semantics
    /// Absolute instant used for sorting and notifications. Derived from `dueLocal`
    /// and `timezoneId`; for approximate periods this is the start of the window.
    public var dueAt: Date?
    public var duePrecision: DuePrecision
    /// The wall-clock deadline as the user meant it.
    public var dueLocal: LocalDateTime?
    /// Inclusive last day of an approximate window ("this week" → Sunday/Saturday).
    public var dueWindowEnd: LocalDateTime?
    /// IANA identifier of the zone the deadline was agreed in.
    public var timezoneId: String
    /// Verbatim deadline phrase ("by Friday at four").
    public var agreedDueText: String?

    public var priority: Priority
    public var notificationPolicyId: String

    // MARK: Additional fields
    public var details: String?
    public var context: String?
    public var notes: String?
    public var tags: [String]
    public var promisedAt: Date
    public var nextAction: String?
    public var nextActionDueAt: Date?
    public var waitingOnPersonId: UUID?
    /// Free-text dependency ("Legal approval", "Mike's figures").
    public var waitingOnText: String?
    public var waitingSince: Date?
    /// Days between waiting check-ins; nil uses the global setting.
    public var waitingCheckinDays: Int?
    public var completedAt: Date?
    public var cancelledAt: Date?
    public var cancelReason: String?
    public var snoozedUntil: Date?
    /// Extra per-item reminders chosen by the user.
    public var customReminders: [Date]
    public var sourceReference: String?
    public var aiExtractionVersion: String?
    /// Field names the extractor flagged as uncertain.
    public var aiConfidenceIndicators: [String]
    public var requiresReview: Bool
    public var isPinned: Bool
    public var isSensitive: Bool
    public var parentCommitmentId: UUID?
    /// Bumped on every change; reminders derive their identifiers from it.
    public var revision: Int

    public init(
        id: UUID = UUID(),
        title: String,
        originalInput: String = "",
        status: CommitmentStatus = .open,
        createdAt: Date,
        sourceType: SourceType = .manual,
        owner: String = "local",
        personId: UUID? = nil,
        dueAt: Date? = nil,
        duePrecision: DuePrecision = .none,
        dueLocal: LocalDateTime? = nil,
        dueWindowEnd: LocalDateTime? = nil,
        timezoneId: String = TimeZone.current.identifier,
        agreedDueText: String? = nil,
        priority: Priority = .normal,
        notificationPolicyId: String = "default",
        details: String? = nil,
        context: String? = nil,
        notes: String? = nil,
        tags: [String] = [],
        promisedAt: Date? = nil,
        nextAction: String? = nil,
        nextActionDueAt: Date? = nil,
        waitingOnPersonId: UUID? = nil,
        waitingOnText: String? = nil,
        waitingSince: Date? = nil,
        waitingCheckinDays: Int? = nil,
        customReminders: [Date] = [],
        sourceReference: String? = nil,
        aiExtractionVersion: String? = nil,
        aiConfidenceIndicators: [String] = [],
        requiresReview: Bool = false,
        isPinned: Bool = false,
        isSensitive: Bool = false,
        parentCommitmentId: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.originalInput = originalInput
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.sourceType = sourceType
        self.owner = owner
        self.personId = personId
        self.dueAt = dueAt
        self.duePrecision = duePrecision
        self.dueLocal = dueLocal
        self.dueWindowEnd = dueWindowEnd
        self.timezoneId = timezoneId
        self.agreedDueText = agreedDueText
        self.priority = priority
        self.notificationPolicyId = notificationPolicyId
        self.details = details
        self.context = context
        self.notes = notes
        self.tags = tags
        self.promisedAt = promisedAt ?? createdAt
        self.nextAction = nextAction
        self.nextActionDueAt = nextActionDueAt
        self.waitingOnPersonId = waitingOnPersonId
        self.waitingOnText = waitingOnText
        self.waitingSince = waitingSince
        self.waitingCheckinDays = waitingCheckinDays
        self.completedAt = nil
        self.cancelledAt = nil
        self.cancelReason = nil
        self.snoozedUntil = nil
        self.customReminders = customReminders
        self.sourceReference = sourceReference
        self.aiExtractionVersion = aiExtractionVersion
        self.aiConfidenceIndicators = aiConfidenceIndicators
        self.requiresReview = requiresReview
        self.isPinned = isPinned
        self.isSensitive = isSensitive
        self.parentCommitmentId = parentCommitmentId
        self.revision = 1
    }

    public var timeZone: TimeZone { TimeZone(identifier: timezoneId) ?? .current }

    /// Calendar in the commitment's own time zone, used for deadline arithmetic.
    public func calendar(base: Calendar) -> Calendar {
        var cal = base
        cal.timeZone = timeZone
        return cal
    }

    public var hasDeadline: Bool { duePrecision != .none && dueLocal != nil }
}

public extension Commitment {
    /// The value bundle describing a deadline, used for editing and rescheduling.
    struct Due: Codable, Hashable, Sendable {
        public var precision: DuePrecision
        public var local: LocalDateTime?
        public var windowEnd: LocalDateTime?
        public var timezoneId: String
        public var phrase: String?

        public init(precision: DuePrecision, local: LocalDateTime? = nil, windowEnd: LocalDateTime? = nil,
                    timezoneId: String = TimeZone.current.identifier, phrase: String? = nil) {
            self.precision = precision
            self.local = local
            self.windowEnd = windowEnd
            self.timezoneId = timezoneId
            self.phrase = phrase
        }

        public static func none(phrase: String? = nil) -> Due {
            Due(precision: .none, phrase: phrase)
        }
    }

    var due: Due {
        Due(precision: duePrecision, local: dueLocal, windowEnd: dueWindowEnd, timezoneId: timezoneId, phrase: agreedDueText)
    }

    /// Applies a deadline and recomputes `dueAt` deterministically.
    mutating func apply(due: Due, baseCalendar: Calendar) {
        // A hard deadline without a date is meaningless; keep it unscheduled instead.
        duePrecision = (due.precision.isHardDeadline && due.local == nil) ? .none : due.precision
        dueLocal = due.local
        dueWindowEnd = due.windowEnd
        timezoneId = due.timezoneId
        agreedDueText = due.phrase
        if let local = due.local {
            var cal = baseCalendar
            cal.timeZone = TimeZone(identifier: due.timezoneId) ?? baseCalendar.timeZone
            dueAt = WallClock.resolve(local, calendar: cal)?.date
        } else {
            dueAt = nil
        }
    }
}
