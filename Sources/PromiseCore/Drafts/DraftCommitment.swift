import Foundation

/// An unconfirmed promise shown on a review card. It never becomes active without an
/// explicit save (PRD §4.5).
public struct DraftCommitment: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var rawText: String
    public var sourceSpan: String?
    public var sourceType: SourceType
    public var capturedAt: Date

    public var title: String
    public var details: String?
    public var notes: String?
    public var recipientName: String?
    public var suggestedRecipient: String?
    public var personMatch: PersonMatch

    public var dateResolution: DateResolution
    /// The deadline that will be saved; nil = unscheduled.
    public var selectedDue: Commitment.Due?
    /// True once the user picked or confirmed a date that needed confirmation.
    public var dateConfirmed: Bool

    public var waitingOn: String?
    public var nextAction: String?
    public var startAsWaiting: Bool
    public var priority: Priority
    public var evidence: [FieldEvidence]
    public var uncertainFields: Set<DraftField>
    /// Existing active commitments that look like this one (non-blocking).
    public var possibleDuplicates: [UUID]
    public var engineId: String

    public init(id: UUID = UUID(), rawText: String, sourceSpan: String? = nil, sourceType: SourceType, capturedAt: Date,
                title: String, details: String? = nil, notes: String? = nil, recipientName: String? = nil,
                suggestedRecipient: String? = nil, personMatch: PersonMatch = .none,
                dateResolution: DateResolution = .unscheduled(phrase: nil), waitingOn: String? = nil,
                nextAction: String? = nil, priority: Priority = .normal, evidence: [FieldEvidence] = [],
                uncertainFields: Set<DraftField> = [], possibleDuplicates: [UUID] = [], engineId: String = "manual") {
        self.id = id
        self.rawText = rawText
        self.sourceSpan = sourceSpan
        self.sourceType = sourceType
        self.capturedAt = capturedAt
        self.title = title
        self.details = details
        self.notes = notes
        self.recipientName = recipientName
        self.suggestedRecipient = suggestedRecipient
        self.personMatch = personMatch
        self.dateResolution = dateResolution
        self.selectedDue = dateResolution.proposed?.due
        self.dateConfirmed = !dateResolution.needsConfirmation
        self.waitingOn = waitingOn
        self.nextAction = nextAction
        // Waiting status is only proposed; the user's save action confirms it.
        self.startAsWaiting = waitingOn != nil
        self.priority = priority
        self.evidence = evidence
        self.uncertainFields = uncertainFields
        self.possibleDuplicates = possibleDuplicates
        self.engineId = engineId
    }

    public var requiresReview: Bool {
        !uncertainFields.isEmpty || dateResolution.needsConfirmation || personMatch.needsReview || !possibleDuplicates.isEmpty
    }

    /// Problems that block saving until the user resolves them.
    public var blockingIssues: [String] {
        var issues: [String] = []
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append("Add what you promised.") }
        if dateResolution.needsConfirmation && !dateConfirmed { issues.append("Confirm the date.") }
        if case .ambiguous = personMatch { issues.append("Choose which person you meant.") }
        return issues
    }

    public var canSave: Bool { blockingIssues.isEmpty }

    // MARK: Edits from the review card

    public mutating func choose(candidate: DueCandidate) {
        selectedDue = candidate.due
        dateConfirmed = true
        uncertainFields.remove(.deadline)
    }

    public mutating func setDue(_ due: Commitment.Due?) {
        selectedDue = due
        dateConfirmed = true
        uncertainFields.remove(.deadline)
    }

    public mutating func choosePerson(_ id: UUID?) {
        personMatch = id.map { .matched($0) } ?? .none
        uncertainFields.remove(.recipient)
    }

    public mutating func createPerson(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        personMatch = trimmed.isEmpty ? .none : .new(trimmed)
        recipientName = trimmed.isEmpty ? nil : trimmed
        uncertainFields.remove(.recipient)
    }
}

/// Result of interpreting one capture.
public struct CaptureResult: Hashable, Sendable {
    public var drafts: [DraftCommitment]
    public var skipped: [SkippedStatement]
    public var engineId: String
    /// Set when on-device AI was not used.
    public var fallbackReason: ExtractionUnavailableReason?
}
