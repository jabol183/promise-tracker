import Foundation

/// Deterministic fallback used when on-device AI is unavailable (PRD Journey G).
/// It only recognizes clear first-person promise patterns; anything else is left to
/// the manual form rather than guessed.
public struct RuleBasedExtractor: PromiseExtracting {
    public let engineId = "rules-1"
    private let scanner: DatePhraseScanner

    public init(lexicon: DateLexicon = .english) {
        scanner = DatePhraseScanner(lexicon: lexicon)
    }

    public func extract(_ text: String, capturedAt: Date) async throws -> PromiseExtraction {
        extractSync(text)
    }

    public func extractSync(_ text: String) -> PromiseExtraction {
        PromiseExtraction(promises: clauses(in: text).compactMap(interpret))
    }

    // MARK: Clause splitting

    /// Splits on sentence ends and on "and I …" so separate promises never merge.
    func clauses(in text: String) -> [String] {
        var parts: [String] = []
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?;\n"))
        let splitter = Self.re("(?:,\\s*|\\s+)(?:and|also|plus|then)\\s+(?:also\\s+)?(?=I\\b|I['’])")
        for sentence in sentences {
            let s = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { continue }
            let ns = s as NSString
            var last = 0
            for m in splitter.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                parts.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
                last = m.range.location + m.range.length
            }
            parts.append(ns.substring(from: last))
        }
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ","))) }.filter { !$0.isEmpty }
    }

    // MARK: Patterns

    private static func re(_ p: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
    }

    private static let apostrophe = "['’]"
    private static let negation = re("\\bI\\s+(?:did\\s+not|didn['’]t|never|have\\s+not|haven['’]t|do\\s+not|don['’]t)\\s+(?:promise|say|agree|tell|offer|commit)|\\bI\\s+(?:won['’]t|will\\s+not|am\\s+not\\s+going\\s+to|['’]m\\s+not\\s+going\\s+to|can['’]t|cannot)\\b")
    private static let hypothetical = re("\\b(?:I\\s+might|I\\s+may|maybe\\s+I|perhaps\\s+I|I\\s+could|I\\s+should\\s+probably|if\\s+I|I['’]m\\s+thinking|I\\s+am\\s+thinking|I\\s+would\\s+like\\s+to|I['’]d\\s+like\\s+to|I\\s+wonder)\\b")
    private static let incoming = re("^(?:(?!I\\b)(?-i:[A-Z])[\\p{L}'’-]*(?:\\s+(?-i:[A-Z])[\\p{L}'’-]*)?|he|she|they)\\s+(?:promised|said|told|owes|agreed|offered|will|is\\s+going\\s+to|['’]ll)\\b.*\\bme\\b")

    /// "I promised Sarah (that) I'd …" / "I told Alex I would …" / "I promised Sarah to …"
    private static let promisedTo = re("\\bI\\s+(?:have\\s+|had\\s+|just\\s+)?(?:promised|told|assured|reassured|guaranteed)\\s+([\\p{L}'’-]+(?:\\s+(?-i:[A-Z])[\\p{L}'’-]*)?)\\s+(?:that\\s+)?(?:I\\s*(?:['’]d|['’]ll|would|will|am\\s+going\\s+to|['’]m\\s+going\\s+to)\\s+|to\\s+)(.+)$")
    /// "I owe Jamie a call"
    private static let owe = re("\\bI\\s+owe\\s+([\\p{L}'’-]+(?:\\s+(?-i:[A-Z])[\\p{L}'’-]*)?)\\s+(.+)$")
    /// "I said I'd …", "I agreed to …", "I promised to …"
    private static let agreed = re("\\bI\\s+(?:said|agreed|offered|committed|promised|volunteered|signed\\s+up)\\s+(?:that\\s+)?(?:I\\s*(?:['’]d|['’]ll|would|will)\\s+|to\\s+)(.+)$")
    /// "I'll …", "I will …", "I'm going to …", "I need to …"
    private static let will = re("\\bI\\s*(?:['’]ll|\\s+will|['’]m\\s+going\\s+to|\\s+am\\s+going\\s+to|['’]m\\s+gonna|\\s+need\\s+to|\\s+have\\s+to|\\s+must|\\s+got\\s+to|['’]ve\\s+got\\s+to)\\s+(.+)$")

    /// "Remind me to …" / "Remember to …" followed by any action.
    private static let remindPrefix = re("^\\s*(?:please\\s+)?(?:remind\\s+me\\s+to|remember\\s+to|don['’]t\\s+forget\\s+to)\\s+(.+)$")

    /// An imperative note to self, optionally introduced by "remind me to" / "remember to".
    private static let noteToSelf = re("^\\s*(?:(?:please\\s+)?(?:remind\\s+me\\s+to|remember\\s+to|don['’]t\\s+forget\\s+to|need\\s+to|have\\s+to|todo:?|to\\s+do:?)\\s+)?((?:send|call|email|e-mail|text|message|ring|phone|pay|buy|get|book|finish|write|bring|return|reply|share|submit|prepare|review|fix|deliver|order|schedule|pick\\s+up|drop\\s+off|follow\\s+up|check|ask|tell|remind|invite|thank|update|organise|organize|sign|renew|cancel|confirm|take|put|clean|wash|water|feed|collect|visit|meet|go|do|make|cook|tidy|walk|empty|mow|file|print|post|pack|pick|drop|lend|hand|transfer|move|install|test|plan|draft|read|watch|finish|start|charge)\\b.+)$")

    private static let pronouns: Set<String> = ["him", "her", "them", "you", "me", "us", "it"]
    private static let notNames: Set<String> = [
        "i", "the", "a", "an", "my", "our", "your", "their", "his", "this", "that", "everyone", "someone", "somebody",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "today", "tomorrow", "tonight",
        "january", "february", "march", "april", "june", "july", "august", "september", "october", "november", "december",
        "siri", "ok", "okay", "hey", "please", "and", "but", "to", "that", "myself",
    ]

    // MARK: Interpretation

    private func interpret(_ clause: String) -> ExtractedPromise? {
        let ns = clause as NSString
        let full = NSRange(location: 0, length: ns.length)
        func first(_ r: NSRegularExpression) -> NSTextCheckingResult? { r.firstMatch(in: clause, range: full) }
        func group(_ m: NSTextCheckingResult, _ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }

        if first(Self.negation) != nil {
            return ExtractedPromise(kind: .negated, title: clause, sourceSpan: clause)
        }
        if first(Self.incoming) != nil && first(Self.promisedTo) == nil && first(Self.will) == nil {
            return ExtractedPromise(kind: .incoming, title: clause, sourceSpan: clause)
        }
        if let h = first(Self.hypothetical) {
            // "If I can, I'll…" is still hypothetical; only a later definite promise overrides.
            let after = ns.substring(from: h.range.location)
            if !after.isEmpty { return ExtractedPromise(kind: .hypothetical, title: clause, sourceSpan: clause) }
        }

        var recipient: String?
        var action: String
        var oweObject: String?

        if let m = first(Self.promisedTo), let who = group(m, 1), let rest = group(m, 2) {
            recipient = name(from: who)
            action = rest
        } else if let m = first(Self.owe), let who = group(m, 1), let rest = group(m, 2) {
            recipient = name(from: who)
            action = rest
            oweObject = rest
        } else if let m = first(Self.agreed), let rest = group(m, 1) {
            action = rest
        } else if let m = first(Self.will), let rest = group(m, 1) {
            action = rest
        } else if let m = first(Self.remindPrefix), let rest = group(m, 1) {
            action = rest
        } else if let m = first(Self.noteToSelf), let rest = group(m, 1) {
            // Notes to self: "Send the deck to Sarah on Tuesday", "Remind me to call Bo".
            action = rest
        } else {
            return nil
        }

        var evidence: [FieldEvidence] = []
        var uncertain: [String] = []

        // Deadline phrase (verbatim) and removal from the action text.
        var deadline: String?
        if let match = scanner.scan(action).first {
            deadline = match.phrase
            action = remove(match.phrase, from: action)
            evidence.append(FieldEvidence(field: "deadlinePhrase", quote: match.phrase))
        }

        // Dependencies: "but I need Mike's figures first", "once Legal approves it".
        var waitingOn: String?
        var nextAction: String?
        let dependencyPatterns: [(NSRegularExpression, (String) -> String)] = [
            (Self.re(",?\\s*(?:but|though|although)?\\s*I\\s+(?:need|have\\s+to\\s+get|must\\s+get|first\\s+need)\\s+(.+?)\\s+first\\b.*$"), { "Get \($0)" }),
            (Self.re(",?\\s*(?:once|as\\s+soon\\s+as|after|when)\\s+([A-Z][\\p{L}'’-]*(?:\\s+[\\p{L}'’-]+){0,4}?\\s+(?:approves|approve|signs|confirms|replies|responds|sends|send|gets\\s+back|has\\s+approved|is\\s+done|finishes|agrees)(?:\\s+.+)?)$"), { "Wait until \($0)" }),
            (Self.re(",?\\s*(?:once|as\\s+soon\\s+as)\\s+(.+)$"), { "Wait until \($0)" }),
        ]
        for (pattern, makeNext) in dependencyPatterns {
            let ans = action as NSString
            if let m = pattern.firstMatch(in: action, range: NSRange(location: 0, length: ans.length)) {
                let dep = ans.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                waitingOn = dep
                nextAction = makeNext(dep)
                evidence.append(FieldEvidence(field: "waitingOn", quote: dep))
                action = ans.replacingCharacters(in: m.range, with: "")
                break
            }
        }

        // Recipient inside the action when not given by the verb ("send Tom the contract", "call Jamie").
        if recipient == nil {
            recipient = recipientInAction(action)
        }
        if let recipient { evidence.append(FieldEvidence(field: "recipientName", quote: recipient)) }
        else if action.range(of: "\\b(him|her|them)\\b", options: [.regularExpression, .caseInsensitive]) != nil {
            uncertain.append("recipient")
        }

        // Priority only when explicit.
        var priority: String?
        if let p = clause.range(of: "\\b(urgent|urgently|asap|as soon as possible|high priority|top priority|important)\\b", options: [.regularExpression, .caseInsensitive]) {
            priority = "high"
            evidence.append(FieldEvidence(field: "explicitPriority", quote: String(clause[p])))
            action = remove(String(clause[p]), from: action)
        }

        let title = makeTitle(action: action, recipient: recipient, oweObject: oweObject)
        guard !title.isEmpty else { return nil }
        if title.split(separator: " ").count < 2 { uncertain.append("title") }

        return ExtractedPromise(kind: .commitment, title: title, recipientName: recipient,
                                actionDescription: nil, deadlinePhrase: deadline, waitingOn: waitingOn,
                                nextAction: nextAction, explicitPriority: priority, evidence: evidence,
                                uncertainFields: uncertain, sourceSpan: clause)
    }

    private func name(from raw: String) -> String? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let words = cleaned.split(separator: " ").map(String.init)
        guard let firstWord = words.first else { return nil }
        let lower = firstWord.lowercased()
        if Self.pronouns.contains(lower) || Self.notNames.contains(lower) { return nil }
        // Names must be capitalized in the source; lowercase words are likely not names.
        guard firstWord.first?.isUppercase == true else { return nil }
        let kept = words.prefix { $0.first?.isUppercase == true && !Self.notNames.contains($0.lowercased()) }
        let joined = kept.joined(separator: " ")
        return joined.isEmpty ? nil : stripPossessive(joined)
    }

    private func stripPossessive(_ s: String) -> String {
        for suffix in ["'s", "’s"] where s.hasSuffix(suffix) { return String(s.dropLast(2)) }
        return s
    }

    private func recipientInAction(_ action: String) -> String? {
        let patterns = [
            "^(?:send|give|email|call|text|ring|phone|pay|show|tell|ask|remind|message|lend|bring|update|help|meet|visit|thank)\\s+([A-Z][\\p{L}'’-]*(?:\\s+[A-Z][\\p{L}'’-]*)?)\\b",
            "\\b(?:to|for|with)\\s+([A-Z][\\p{L}'’-]*(?:\\s+[A-Z][\\p{L}'’-]*)?)\\b",
            "\\bback\\s+to\\s+([A-Z][\\p{L}'’-]*)\\b",
        ]
        for p in patterns {
            let r = try! NSRegularExpression(pattern: p) // case-sensitive: names are capitalized
            let ns = action as NSString
            if let m = r.firstMatch(in: action, range: NSRange(location: 0, length: ns.length)) {
                let candidate = ns.substring(with: m.range(at: 1))
                if let n = name(from: candidate) { return n }
            }
        }
        return nil
    }

    private func remove(_ phrase: String, from text: String) -> String {
        guard let r = text.range(of: phrase, options: [.caseInsensitive]) else { return text }
        var out = text
        out.removeSubrange(r)
        return out.replacingOccurrences(of: "  ", with: " ")
    }

    private func makeTitle(action: String, recipient: String?, oweObject: String?) -> String {
        var a = action.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        // Drop dangling connectives left after removing date/dependency phrases.
        let trailing = Self.re("(?:\\s*,)?\\s+(?:but|and|so|though|then|by|on|at|before|until|for)\\s*$")
        while let m = trailing.firstMatch(in: a, range: NSRange(location: 0, length: (a as NSString).length)) {
            a = (a as NSString).replacingCharacters(in: m.range, with: "").trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        }

        if let obj = oweObject {
            let o = a.trimmingCharacters(in: .whitespaces)
            let lower = o.lowercased()
            let who = recipient ?? "them"
            let verbs: [(String, String)] = [("a call", "Call"), ("a phone call", "Call"), ("a ring", "Call"), ("an email", "Email"),
                                             ("a text", "Text"), ("a message", "Message"), ("a reply", "Reply to"),
                                             ("an answer", "Reply to"), ("a response", "Reply to"), ("an update", "Send an update to")]
            for (noun, verb) in verbs where lower.hasPrefix(noun) {
                let remainder = o.dropFirst(noun.count).trimmingCharacters(in: .whitespaces)
                return ([verb, who] + (remainder.isEmpty ? [] : [remainder])).joined(separator: " ")
            }
            _ = obj
            return "Get \(who) \(o)".trimmingCharacters(in: .whitespaces)
        }

        // "send her the proposal" → "Send the proposal" (the recipient is shown separately).
        a = a.replacingOccurrences(of: "^(\\p{L}+)\\s+(?:her|him|them)\\s+(?=\\p{L})", with: "$1 ", options: [.regularExpression, .caseInsensitive])
        a = a.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        guard let first = a.first else { return "" }
        return first.uppercased() + a.dropFirst()
    }
}
