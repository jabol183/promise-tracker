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

    func makeDraft(_ validated: ValidatedPromise, rawText: String, source: SourceType, capturedAt: Date,
                   people: [Person], existing: [Commitment], engine: String) -> DraftCommitment {
        let p = recoverDeadline(validated, source: rawText)
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

    /// When an extractor left the deadline words inside the title ("Send it to Sarah on
    /// Tuesday"), find them deterministically and move them out of the title. Only the
    /// title is searched: a date elsewhere in the source may describe when the promise was
    /// made, not when it is due. Recovered deadlines are flagged for review.
    func recoverDeadline(_ p: ValidatedPromise, source: String) -> ValidatedPromise {
        guard p.deadlinePhrase == nil else { return p }
        var out = p
        if let match = resolver.scanner.scan(p.title).first,
           source.range(of: match.phrase, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
            // Deadline words were left inside the title.
            out.deadlinePhrase = match.phrase
            out.title = Self.removing(match.phrase, from: p.title)
        } else if let phrase = deadlineAfterAction(title: p.title, span: p.sourceSpan ?? source) {
            // The model dropped the deadline entirely ("Take the rubbish out at 5 pm today").
            out.deadlinePhrase = phrase
        } else {
            return p
        }
        out.uncertainFields.insert(.deadline)
        return out
    }

    /// A date phrase in the user's words that comes *after* the action, so it modifies the
    /// action. A date before the action ("On Tuesday I promised Sarah I'd send…") usually
    /// says when the promise was made, so it is ignored.
    func deadlineAfterAction(title: String, span: String) -> String? {
        guard let verb = TextNormalizer.tokens(title).first, verb.count >= 2 else { return nil }
        let chars = Array(span)
        let normalized = Array(DatePhraseScanner.alignedNormalize(chars))
        // Character offset where the action's first word starts in the span (whole word).
        var actionStart: Int?
        let verbChars = Array(verb)
        if normalized.count >= verbChars.count {
            for i in 0...(normalized.count - verbChars.count) where Array(normalized[i..<(i + verbChars.count)]) == verbChars {
                let before = i == 0 ? " " : normalized[i - 1]
                let afterIndex = i + verbChars.count
                let after = afterIndex < normalized.count ? normalized[afterIndex] : " "
                if !before.isLetter && !before.isNumber && !after.isLetter && !after.isNumber { actionStart = i; break }
            }
        }
        guard let start = actionStart else { return nil }
        return resolver.scanner.scan(span).first { $0.range.lowerBound > start }?.phrase
    }

    static func removing(_ phrase: String, from title: String) -> String {
        guard let r = title.range(of: phrase, options: [.caseInsensitive]) else { return title }
        var t = title
        t.removeSubrange(r)
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "(?:\\s*,)?\\s+(?:by|on|at|before|until|for|and)\\s*$", with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;-")))
        return t.isEmpty ? title : t
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
