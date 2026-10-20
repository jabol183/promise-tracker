import Foundation

/// Orchestrates the capture pipeline (PRD §8.1):
/// text → (AI or rules) → validation → deterministic dates → person resolution →
/// duplicate check → editable drafts. Nothing is saved here.
public struct CaptureInterpreter: Sendable {
    public var primary: (any PromiseExtracting)?
    public var fallback: RuleBasedExtractor
    public var validator = ExtractionValidator()
    public var matcher = PersonMatcher()
    public var resolver: DateResolver

    public init(primary: (any PromiseExtracting)?, fallback: RuleBasedExtractor = RuleBasedExtractor(), resolver: DateResolver) {
        self.primary = primary
        self.fallback = fallback
        self.resolver = resolver
    }

    public func interpret(_ text: String, source: SourceType, capturedAt: Date, people: [Person],
                          existing: [Commitment], unavailableReason: ExtractionUnavailableReason? = nil) async -> CaptureResult {
        let input = TextNormalizer.sanitize(text, maxLength: 4000)
        guard !input.isEmpty else { return CaptureResult(drafts: [], skipped: [], engineId: fallback.engineId, fallbackReason: unavailableReason) }

        var extraction: PromiseExtraction
        var engine: String
        var reason = unavailableReason
        if let primary, reason == nil {
            do {
                extraction = try await primary.extract(input, capturedAt: capturedAt)
                engine = primary.engineId
            } catch let ExtractionError.unavailable(r) {
                reason = r
                extraction = fallback.extractSync(input)
                engine = fallback.engineId
            } catch {
                reason = .runtimeError
                extraction = fallback.extractSync(input)
                engine = fallback.engineId
            }
        } else {
            reason = reason ?? (primary == nil ? .frameworkMissing : nil)
            extraction = fallback.extractSync(input)
            engine = fallback.engineId
        }

        let validated = validator.validate(extraction, source: input)
        let drafts = validated.promises.map { p in
            makeDraft(p, rawText: input, source: source, capturedAt: capturedAt, people: people, existing: existing, engine: engine)
        }
        return CaptureResult(drafts: drafts, skipped: validated.skipped, engineId: engine, fallbackReason: reason)
    }

    /// Builds a draft from the manual form (no extraction).
    public func manualDraft(title: String, personName: String?, duePhrase: String?, capturedAt: Date,
                            people: [Person], existing: [Commitment], source: SourceType = .manual) -> DraftCommitment {
        let resolution = resolver.resolve(duePhrase, anchor: capturedAt)
        var draft = DraftCommitment(rawText: title, sourceType: source, capturedAt: capturedAt, title: title,
                                    recipientName: personName, personMatch: matcher.match(name: personName, in: people),
                                    dateResolution: resolution, engineId: "manual")
        draft.possibleDuplicates = duplicates(of: draft, existing: existing)
        return draft
    }

    func makeDraft(_ p: ValidatedPromise, rawText: String, source: SourceType, capturedAt: Date,
                   people: [Person], existing: [Commitment], engine: String) -> DraftCommitment {
        let resolution = resolver.resolve(p.deadlinePhrase, anchor: capturedAt)
        var uncertain = p.uncertainFields
        if resolution.needsConfirmation { uncertain.insert(.deadline) }
        let match = matcher.match(name: p.recipientName, in: people)
        if match.needsReview { uncertain.insert(.recipient) }
        var draft = DraftCommitment(rawText: rawText, sourceSpan: p.sourceSpan, sourceType: source, capturedAt: capturedAt,
                                    title: p.title, details: p.details, recipientName: p.recipientName,
                                    suggestedRecipient: p.suggestedRecipient, personMatch: match, dateResolution: resolution,
                                    waitingOn: p.waitingOn, nextAction: p.nextAction, priority: p.priority ?? .normal,
                                    evidence: p.evidence, uncertainFields: uncertain, engineId: engine)
        draft.possibleDuplicates = duplicates(of: draft, existing: existing)
        return draft
    }

    /// Similar title + same person (+ same day when both dated) among active items.
    public func duplicates(of draft: DraftCommitment, existing: [Commitment]) -> [UUID] {
        let draftTokens = Set(TextNormalizer.tokens(draft.title).filter { $0.count > 2 })
        guard !draftTokens.isEmpty else { return [] }
        return existing.filter { c in
            guard c.status.isActive else { return false }
            if let pid = draft.personMatch.resolvedPersonId, c.personId != pid { return false }
            if draft.personMatch.resolvedPersonId == nil, c.personId != nil, draft.recipientName != nil { return false }
            let tokens = Set(TextNormalizer.tokens(c.title).filter { $0.count > 2 })
            let jaccard = Double(draftTokens.intersection(tokens).count) / Double(max(1, draftTokens.union(tokens).count))
            guard jaccard >= 0.6 else { return false }
            if let a = draft.selectedDue?.local?.dateOnly, let b = c.dueLocal?.dateOnly { return a == b }
            return true
        }.map(\.id)
    }
}
