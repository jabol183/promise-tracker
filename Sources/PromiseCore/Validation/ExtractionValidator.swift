import Foundation

/// A model or rule output that passed validation and grounding checks.
public struct ValidatedPromise: Hashable, Sendable {
    public var title: String
    public var details: String?
    /// Only set when the name literally appears in the user's words.
    public var recipientName: String?
    /// A name the extractor proposed that is *not* in the text; shown as a suggestion only.
    public var suggestedRecipient: String?
    public var deadlinePhrase: String?
    public var waitingOn: String?
    public var nextAction: String?
    public var priority: Priority?
    public var evidence: [FieldEvidence]
    public var uncertainFields: Set<DraftField>
    public var sourceSpan: String?
}

public struct ValidatedExtraction: Hashable, Sendable {
    public var promises: [ValidatedPromise]
    public var skipped: [SkippedStatement]
}

/// Strict validation and evidence checks applied to *every* extractor's output
/// (PRD §8.1). Source text is data: nothing the model returns is trusted unless it is
/// grounded in what the user actually said.
public struct ExtractionValidator: Sendable {
    public static let maxPromises = 10
    public static let maxTitleLength = 140
    public static let maxFieldLength = 500

    public init() {}

    public func validate(_ extraction: PromiseExtraction, source: String) -> ValidatedExtraction {
        let sourceNorm = TextNormalizer.normalize(source)
        let sourceTokens = Set(TextNormalizer.tokens(source))
        var promises: [ValidatedPromise] = []
        var skipped: [SkippedStatement] = []

        for item in extraction.promises.prefix(Self.maxPromises * 2) {
            let span = item.sourceSpan.map { TextNormalizer.sanitize($0, maxLength: Self.maxFieldLength) }
            switch item.kind {
            case .incoming: skipped.append(SkippedStatement(text: span ?? item.title, reason: .incoming)); continue
            case .negated: skipped.append(SkippedStatement(text: span ?? item.title, reason: .negated)); continue
            case .hypothetical: skipped.append(SkippedStatement(text: span ?? item.title, reason: .hypothetical)); continue
            case .commitment: break
            }

            let title = TextNormalizer.sanitize(item.title, maxLength: Self.maxTitleLength)
            guard !title.isEmpty else { continue }

            // Grounding: a title with no content words from the source is treated as fabricated.
            let titleTokens = TextNormalizer.tokens(title).filter { $0.count > 2 && !Self.stopwords.contains($0) }
            let grounded = titleTokens.filter { token in sourceTokens.contains(token) || sourceTokens.contains { $0.hasPrefix(token.prefix(4)) && token.count >= 4 } }
            if !titleTokens.isEmpty && grounded.isEmpty {
                skipped.append(SkippedStatement(text: title, reason: .ungrounded))
                continue
            }

            var uncertain = Set(item.uncertainFields.compactMap { Self.fieldAliases[$0.lowercased()] })
            if titleTokens.count > 0 && grounded.count * 2 < titleTokens.count { uncertain.insert(.title) }

            var recipient: String?
            var suggested: String?
            if let raw = item.recipientName.map({ TextNormalizer.sanitize($0, maxLength: 80) }), !raw.isEmpty {
                if contains(sourceNorm, phrase: raw) {
                    recipient = raw
                } else {
                    suggested = raw
                    uncertain.insert(.recipient)
                }
            }

            var deadline: String?
            if let raw = item.deadlinePhrase.map({ TextNormalizer.sanitize($0, maxLength: 120) }), !raw.isEmpty {
                if contains(sourceNorm, phrase: raw) { deadline = verbatim(raw, in: source) }
                else { uncertain.insert(.deadline) }
            }

            var waitingOn: String?
            if let raw = item.waitingOn.map({ TextNormalizer.sanitize($0, maxLength: 200) }), !raw.isEmpty {
                if mostlyGrounded(raw, in: sourceTokens) { waitingOn = raw } else { uncertain.insert(.waitingOn) }
            }

            var priority: Priority?
            if let raw = item.explicitPriority?.lowercased(), let p = Priority(rawValue: raw), p != .normal {
                let priorityWords = ["urgent", "asap", "important", "priority", "critical", "whenever", "no rush", "low"]
                let hasEvidence = item.evidence.contains { $0.field.lowercased().contains("priority") && contains(sourceNorm, phrase: $0.quote) }
                    || priorityWords.contains { sourceNorm.contains($0) }
                if hasEvidence { priority = p } else { uncertain.insert(.priority) }
            }

            let nextAction = item.nextAction.map { TextNormalizer.sanitize($0, maxLength: 200) }.flatMap { $0.isEmpty ? nil : $0 }
            let details = item.actionDescription.map { TextNormalizer.sanitize($0, maxLength: Self.maxFieldLength) }.flatMap { $0.isEmpty ? nil : $0 }
            let evidence = item.evidence.filter { contains(sourceNorm, phrase: $0.quote) }

            promises.append(ValidatedPromise(title: title, details: details, recipientName: recipient, suggestedRecipient: suggested,
                                             deadlinePhrase: deadline, waitingOn: waitingOn, nextAction: nextAction,
                                             priority: priority, evidence: evidence, uncertainFields: uncertain, sourceSpan: span))
            if promises.count >= Self.maxPromises { break }
        }
        return ValidatedExtraction(promises: dedupe(promises), skipped: skipped)
    }

    // MARK: Helpers

    static let stopwords: Set<String> = ["the", "and", "for", "with", "her", "him", "them", "his", "their", "about", "from", "that", "this", "send", "get", "make", "give", "call", "back"]

    static let fieldAliases: [String: DraftField] = [
        "title": .title, "recipient": .recipient, "recipientname": .recipient, "person": .recipient,
        "deadline": .deadline, "deadlinephrase": .deadline, "date": .deadline, "due": .deadline,
        "waitingon": .waitingOn, "dependency": .waitingOn, "nextaction": .nextAction, "priority": .priority,
        "explicitpriority": .priority,
    ]

    private func contains(_ normalizedSource: String, phrase: String) -> Bool {
        let p = TextNormalizer.normalize(phrase)
        guard !p.isEmpty else { return false }
        return normalizedSource.contains(p)
    }

    private func mostlyGrounded(_ text: String, in sourceTokens: Set<String>) -> Bool {
        let tokens = TextNormalizer.tokens(text).filter { $0.count > 2 }
        guard !tokens.isEmpty else { return false }
        return tokens.filter(sourceTokens.contains).count * 2 >= tokens.count
    }

    /// Returns the phrase exactly as it was written in the source (original casing/diacritics).
    private func verbatim(_ phrase: String, in source: String) -> String {
        if let r = source.range(of: phrase, options: [.caseInsensitive, .diacriticInsensitive]) { return String(source[r]) }
        return phrase
    }

    private func dedupe(_ list: [ValidatedPromise]) -> [ValidatedPromise] {
        var seen = Set<String>()
        return list.filter { seen.insert(TextNormalizer.normalize($0.title) + "|" + TextNormalizer.normalize($0.recipientName ?? "")).inserted }
    }
}
