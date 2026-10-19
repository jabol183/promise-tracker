import Foundation

/// Deterministic follow-up message drafts, used when on-device AI is unavailable
/// (FR-10). Drafts are editable text only; nothing is ever sent by the app.
public enum FollowUpTone: String, CaseIterable, Codable, Sendable {
    case friendly, formal, short

    public var label: String {
        switch self {
        case .friendly: return "Friendly"
        case .formal: return "Make it more formal"
        case .short: return "Make it shorter"
        }
    }
}

public enum FollowUpKind: String, CaseIterable, Codable, Sendable {
    case delivered, statusUpdate, apologyLate, checkingIn
}

public struct FollowUpTemplates: Sendable {
    public init() {}

    public func suggestedKind(for c: Commitment, isOverdue: Bool) -> FollowUpKind {
        if c.status == .completed { return .delivered }
        if c.status == .waiting { return .checkingIn }
        return isOverdue ? .apologyLate : .statusUpdate
    }

    public func draft(for c: Commitment, recipient: String?, sender: String?, kind: FollowUpKind, tone: FollowUpTone,
                      keyPoints: [String] = []) -> String {
        let firstName = recipient?.split(separator: " ").first.map(String.init)
        let greeting: String
        switch tone {
        case .formal: greeting = firstName.map { "Dear \($0)," } ?? "Hello,"
        case .friendly: greeting = firstName.map { "Hi \($0)," } ?? "Hi,"
        case .short: greeting = firstName.map { "Hi \($0) —" } ?? "Hi —"
        }
        let what = lowerFirst(c.title)
        var body: String
        switch (kind, tone) {
        case (.delivered, .short): body = "as promised, I’ve \(pastTense(what))."
        case (.delivered, _): body = "As promised, I’ve \(pastTense(what)). Let me know if you have any questions or if there’s anything else you’d like me to include."
        case (.statusUpdate, .short): body = "quick update: I’m on track to \(what)."
        case (.statusUpdate, _): body = "A quick update on my promise to \(what): it’s in progress and I’ll be in touch as soon as it’s ready."
        case (.apologyLate, .short): body = "sorry — I’m running late on \(gerundPhrase(what)). I’ll send it shortly."
        case (.apologyLate, .formal): body = "Please accept my apologies for the delay in \(gerundPhrase(what)). I will have it with you shortly."
        case (.apologyLate, .friendly): body = "Sorry I’m running behind on \(gerundPhrase(what)). I haven’t forgotten, and I’ll have it with you shortly."
        case (.checkingIn, .short): body = "checking in — any news on \(c.waitingOnText ?? "this")?"
        case (.checkingIn, _):
            let on = c.waitingOnText.map { " I’m still waiting on \($0) before I can \(what)." } ?? ""
            body = "Just checking in.\(on) Is there anything I can do to move it along?"
        }
        if !keyPoints.isEmpty {
            body += "\n\n" + keyPoints.map { "• \($0)" }.joined(separator: "\n")
        }
        let closing: String
        switch tone {
        case .formal: closing = "\n\nKind regards,"
        case .friendly: closing = "\n\nBest regards,"
        case .short: closing = ""
        }
        let signature = sender.map { "\n\($0)" } ?? ""
        return "\(greeting)\n\n\(body)\(closing)\(signature)"
    }

    private func lowerFirst(_ s: String) -> String {
        guard let f = s.first else { return s }
        if s.count > 1, s[s.index(after: s.startIndex)].isUppercase { return s } // acronym
        return f.lowercased() + s.dropFirst()
    }

    private func pastTense(_ phrase: String) -> String {
        let irregular = ["send": "sent", "give": "given", "make": "made", "write": "written", "bring": "brought",
                         "buy": "bought", "do": "done", "get": "got", "pay": "paid", "find": "found", "lend": "lent",
                         "call": "called", "email": "emailed", "share": "shared", "finish": "finished"]
        let words = phrase.split(separator: " ", maxSplits: 1).map(String.init)
        guard let verb = words.first?.lowercased() else { return phrase }
        let rest = words.count > 1 ? " " + words[1] : ""
        if let p = irregular[verb] { return p + rest }
        if verb.hasSuffix("e") { return verb + "d" + rest }
        return verb + "ed" + rest
    }

    private func gerundPhrase(_ phrase: String) -> String {
        let words = phrase.split(separator: " ", maxSplits: 1).map(String.init)
        guard var verb = words.first?.lowercased() else { return phrase }
        let rest = words.count > 1 ? " " + words[1] : ""
        if verb.hasSuffix("ie") { verb = String(verb.dropLast(2)) + "y" }
        else if verb.hasSuffix("e") && !verb.hasSuffix("ee") { verb = String(verb.dropLast()) }
        return verb + "ing" + rest
    }
}
