import Foundation

/// Framework-neutral mirror of the guided-generation schema (PRD §8.2). The Foundation
/// Models adapter maps its `@Generable` output into these types so the domain never
/// depends on AI framework types.
public struct PromiseExtraction: Codable, Hashable, Sendable {
    public var promises: [ExtractedPromise]
    public init(promises: [ExtractedPromise]) { self.promises = promises }
}

public enum ExtractedStatementKind: String, Codable, Hashable, Sendable {
    /// Something the speaker promised or owns.
    case commitment
    /// Someone promised the speaker ("Sarah promised me a quote").
    case incoming
    /// "I did not promise to send it."
    case negated
    /// "I might tell Alex I'll help."
    case hypothetical
}

public struct FieldEvidence: Codable, Hashable, Sendable {
    public var field: String
    public var quote: String
    public init(field: String, quote: String) {
        self.field = field
        self.quote = quote
    }
}

public struct ExtractedPromise: Codable, Hashable, Sendable {
    public var kind: ExtractedStatementKind
    public var title: String
    public var recipientName: String?
    public var actionDescription: String?
    public var deadlinePhrase: String?
    public var waitingOn: String?
    public var nextAction: String?
    public var explicitPriority: String?
    public var evidence: [FieldEvidence]
    public var uncertainFields: [String]
    /// The part of the input this promise came from.
    public var sourceSpan: String?

    public init(kind: ExtractedStatementKind = .commitment, title: String, recipientName: String? = nil,
                actionDescription: String? = nil, deadlinePhrase: String? = nil, waitingOn: String? = nil,
                nextAction: String? = nil, explicitPriority: String? = nil, evidence: [FieldEvidence] = [],
                uncertainFields: [String] = [], sourceSpan: String? = nil) {
        self.kind = kind
        self.title = title
        self.recipientName = recipientName
        self.actionDescription = actionDescription
        self.deadlinePhrase = deadlinePhrase
        self.waitingOn = waitingOn
        self.nextAction = nextAction
        self.explicitPriority = explicitPriority
        self.evidence = evidence
        self.uncertainFields = uncertainFields
        self.sourceSpan = sourceSpan
    }
}

/// Fields a draft can flag for review.
public enum DraftField: String, Codable, CaseIterable, Hashable, Sendable {
    case title, recipient, deadline, waitingOn, nextAction, priority
}

/// Something in the input that was recognized but deliberately not turned into a promise.
public struct SkippedStatement: Codable, Hashable, Sendable {
    public enum Reason: String, Codable, Sendable { case incoming, negated, hypothetical, ungrounded }
    public var text: String
    public var reason: Reason

    public init(text: String, reason: Reason) {
        self.text = text
        self.reason = reason
    }

    public var explanation: String {
        switch reason {
        case .incoming: return "This sounds like someone else’s promise to you, so it wasn’t added as yours."
        case .negated: return "This says you didn’t promise, so nothing was added."
        case .hypothetical: return "This sounds like a maybe, not a promise, so it wasn’t added."
        case .ungrounded: return "A suggested item didn’t match your words, so it was left out."
        }
    }
}

/// Why on-device AI wasn't used for a capture.
public enum ExtractionUnavailableReason: String, Codable, Hashable, Sendable {
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unsupportedLocale
    case frameworkMissing
    case runtimeError
    case disabledByUser

    public var userMessage: String {
        switch self {
        case .deviceNotEligible: return "This iPhone doesn’t support Apple Intelligence. Basic recognition is used instead."
        case .appleIntelligenceNotEnabled: return "Apple Intelligence is turned off. Basic recognition is used instead."
        case .modelNotReady: return "The on-device model is still downloading. Basic recognition is used for now."
        case .unsupportedLocale: return "On-device AI doesn’t support your language yet. Basic recognition is used instead."
        case .frameworkMissing: return "On-device AI needs a newer iOS version. Basic recognition is used instead."
        case .runtimeError: return "On-device AI couldn’t read that. Basic recognition was used instead."
        case .disabledByUser: return "On-device AI is turned off in Settings."
        }
    }
}

public enum ExtractionError: Error, Sendable {
    case unavailable(ExtractionUnavailableReason)
    case failed(String)
}

/// Anything that can turn text into the extraction contract.
public protocol PromiseExtracting: Sendable {
    var engineId: String { get }
    func extract(_ text: String, capturedAt: Date) async throws -> PromiseExtraction
}
