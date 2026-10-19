import Foundation

/// A recognized piece of a deadline phrase.
public enum DateComponent: Hashable, Sendable {
    public enum WeekdayModifier: Hashable, Sendable { case none, this, next }
    public enum Window: Hashable, Sendable {
        case thisWeek, nextWeek, thisWeekend, nextWeekend, thisMonth, nextMonth, coupleOfDays, fewDays
    }
    public enum Meridiem: Hashable, Sendable { case am, pm }

    // Day parts
    case today
    case tonight
    case tomorrow
    case dayAfterTomorrow
    /// weekday: 1 = Sunday … 7 = Saturday (Calendar convention).
    case weekday(Int, WeekdayModifier)
    case monthDay(month: Int, day: Int, year: Int?)
    /// "24/10" — order depends on locale unless one part exceeds 12.
    case numericDate(first: Int, second: Int, year: Int?)
    case dayOfMonth(Int)
    case offsetDays(Int)
    case offsetMonths(Int)
    case window(Window)
    case endOfMonth
    case vague
    case eventLinked

    // Time parts
    case clock(hour: Int, minute: Int, meridiem: Meridiem?)
    case noon
    case midnight
    case morning
    case afternoon
    case evening
    case endOfDay
    case offsetMinutes(Int)

    public var isTime: Bool {
        switch self {
        case .clock, .noon, .midnight, .morning, .afternoon, .evening, .endOfDay, .offsetMinutes: return true
        default: return false
        }
    }
}

/// A verbatim deadline phrase found in text.
public struct DatePhraseMatch: Hashable, Sendable {
    /// Exact substring of the original text, including a leading "by"/"on" if present.
    public var phrase: String
    /// Character offsets into the original text.
    public var range: Range<Int>
    public var components: [DateComponent]
}

public struct DatePhraseScanner: Sendable {
    public let lexicon: DateLexicon
    private let rules: [Rule]

    public init(lexicon: DateLexicon = .english) {
        self.lexicon = lexicon
        self.rules = Self.buildRules(lexicon)
    }

    // MARK: Public API

    /// Finds deadline phrases in free text. Adjacent pieces ("by Friday" + "at four")
    /// are merged into one phrase.
    public func scan(_ text: String) -> [DatePhraseMatch] {
        let original = Array(text)
        let normalized = Self.alignedNormalize(original)
        let ns = normalized as NSString
        let full = NSRange(location: 0, length: ns.length)

        var raw: [(range: Range<Int>, component: DateComponent)] = []
        for rule in rules {
            for m in rule.regex.matches(in: normalized, range: full) {
                guard let r = Range(m.range, in: normalized) else { continue }
                let lower = normalized.distance(from: normalized.startIndex, to: r.lowerBound)
                let upper = normalized.distance(from: normalized.startIndex, to: r.upperBound)
                let groups: [String?] = (0..<m.numberOfRanges).map { i in
                    let gr = m.range(at: i)
                    return gr.location == NSNotFound ? nil : ns.substring(with: gr)
                }
                if let component = rule.build(groups) {
                    raw.append((lower..<upper, component))
                }
            }
        }

        // Prefer longer matches; drop anything overlapping an accepted match.
        raw.sort { ($0.range.count, -$0.range.lowerBound) > ($1.range.count, -$1.range.lowerBound) }
        var accepted: [(range: Range<Int>, component: DateComponent)] = []
        for candidate in raw where !accepted.contains(where: { $0.range.overlaps(candidate.range) }) {
            accepted.append(candidate)
        }
        accepted.sort { $0.range.lowerBound < $1.range.lowerBound }

        // Merge neighbours separated only by connective words.
        var groups: [(range: Range<Int>, components: [DateComponent])] = []
        for item in accepted {
            if let last = groups.last {
                let gap = String(normalized.dropFirst(last.range.upperBound).prefix(max(0, item.range.lowerBound - last.range.upperBound)))
                if isConnective(gap) {
                    groups[groups.count - 1] = (last.range.lowerBound..<item.range.upperBound, last.components + [item.component])
                    continue
                }
            }
            groups.append((item.range, [item.component]))
        }

        return groups.map { group in
            let start = extendLeftForPreposition(normalized, start: group.range.lowerBound)
            let phrase = String(original[start..<group.range.upperBound]).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            return DatePhraseMatch(phrase: phrase, range: start..<group.range.upperBound, components: group.components)
        }
    }

    /// All components recognized anywhere in a phrase (used to interpret a phrase the
    /// model or the user supplied).
    public func components(in phrase: String) -> [DateComponent] {
        scan(phrase).flatMap(\.components)
    }

    // MARK: Internals

    struct Rule: @unchecked Sendable {
        let regex: NSRegularExpression
        let build: ([String?]) -> DateComponent?
    }

    /// Normalizes character-by-character so offsets line up with the original text.
    static func alignedNormalize(_ chars: [Character]) -> String {
        var out = ""
        out.reserveCapacity(chars.count)
        for ch in chars {
            let n = TextNormalizer.normalize(String(ch))
            if let first = n.first, n.count == 1 { out.append(first) }
            else if ch.isWhitespace { out.append(" ") }
            else if let first = n.first { out.append(first) }
            else { out.append(" ") }
        }
        return out
    }

    private func isConnective(_ gap: String) -> Bool {
        let words = gap.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "'")))
            .filter { !$0.isEmpty }
        let connectives: Set<String> = Set(["at", "on", "by", "around", "in", "the", "of", "before"] + lexicon.timePrepositions + lexicon.prepositions.filter { !$0.contains(" ") })
        let punctuationOnly = gap.trimmingCharacters(in: .whitespaces).allSatisfy { ",-–".contains($0) }
        return punctuationOnly || (words.count <= 2 && words.allSatisfy { connectives.contains($0) })
    }

    private func extendLeftForPreposition(_ normalized: String, start: Int) -> Int {
        let prefix = String(normalized.prefix(start))
        for prep in lexicon.prepositions.sorted(by: { $0.count > $1.count }) {
            let needle = prep + " "
            if prefix.hasSuffix(needle) {
                let candidateStart = start - needle.count
                let before = candidateStart > 0 ? Array(prefix)[candidateStart - 1] : " "
                if before.isWhitespace || before.isPunctuation { return candidateStart }
            }
        }
        return start
    }

    private static func alt(_ words: [String]) -> String {
        words.sorted { $0.count > $1.count }.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
    }

    private static let lb = "(?<![\\p{L}\\p{N}])"
    private static let rb = "(?![\\p{L}\\p{N}])"

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns are built from static lexicons; a failure is a programming error.
        try! NSRegularExpression(pattern: lb + "(?:" + pattern + ")" + rb, options: [.caseInsensitive])
    }

    private static func index(of word: String?, in table: [[String]]) -> Int? {
        guard let word = word?.lowercased() else { return nil }
        return table.firstIndex { $0.contains(word) }
    }

    static func buildRules(_ lx: DateLexicon) -> [Rule] {
        var rules: [Rule] = []
        func add(_ pattern: String, _ build: @escaping ([String?]) -> DateComponent?) {
            rules.append(Rule(regex: regex(pattern), build: build))
        }
        func fixed(_ words: [String], _ component: DateComponent) {
            guard !words.isEmpty else { return }
            add(alt(words)) { _ in component }
        }

        let weekdayAlt = alt(lx.weekdays.flatMap { $0 })
        let monthAlt = alt(lx.months.flatMap { $0 })
        let numberAlt = alt(lx.numberWords.flatMap { $0 })
        let oneAlt = alt(lx.articleOne)
        let meridiem = "(am|pm|a\\.m\\.?|p\\.m\\.?)"
        let ordinal = "(?:st|nd|rd|th)?"

        func number(_ s: String?) -> Int? {
            guard let s = s?.lowercased() else { return nil }
            if let n = Int(s) { return n }
            if lx.articleOne.contains(s) { return 1 }
            if let i = index(of: s, in: lx.numberWords) { return i + 1 }
            return nil
        }
        func meridiemValue(_ s: String?) -> DateComponent.Meridiem? {
            guard let s = s?.lowercased() else { return nil }
            return s.hasPrefix("a") ? .am : (s.hasPrefix("p") ? .pm : nil)
        }

        // Fixed vocabulary
        fixed(lx.dayAfterTomorrow, .dayAfterTomorrow)
        fixed(lx.tomorrow, .tomorrow)
        fixed(lx.tonight, .tonight)
        fixed(lx.today, .today)
        fixed(lx.nextWeekend, .window(.nextWeekend))
        fixed(lx.thisWeekend, .window(.thisWeekend))
        fixed(lx.nextWeek, .window(.nextWeek))
        fixed(lx.thisWeek, .window(.thisWeek))
        fixed(lx.nextMonth, .window(.nextMonth))
        fixed(lx.thisMonth, .window(.thisMonth))
        fixed(lx.endOfMonth, .endOfMonth)
        fixed(lx.coupleOfDays, .window(.coupleOfDays))
        fixed(lx.fewDays, .window(.fewDays))
        fixed(lx.endOfDay, .endOfDay)
        fixed(lx.noon, .noon)
        fixed(lx.midnight, .midnight)
        fixed(lx.morning, .morning)
        fixed(lx.afternoon, .afternoon)
        fixed(lx.evening, .evening)
        fixed(lx.vague, .vague)
        fixed(lx.eventLinked, .eventLinked)

        // Weekday with optional modifier
        let thisAlt = alt(lx.thisModifiers)
        let nextAlt = alt(lx.nextModifiers)
        add("(?:(\(thisAlt))\\s+|(\(nextAlt))\\s+)?(\(weekdayAlt))") { g in
            guard let idx = index(of: g[3], in: lx.weekdays) else { return nil }
            let modifier: DateComponent.WeekdayModifier = g[2] != nil ? .next : (g[1] != nil ? .this : .none)
            return .weekday(idx + 1, modifier)
        }

        // "October 24th, 2026" / "24 October" / "the 24th of October"
        add("(\(monthAlt))\\.?\\s+(\\d{1,2})\(ordinal)(?:,?\\s+(\\d{4}))?") { g in
            guard let m = index(of: g[1], in: lx.months), let d = Int(g[2] ?? "") else { return nil }
            return .monthDay(month: m + 1, day: d, year: g[3].flatMap { Int($0) })
        }
        add("(?:the\\s+)?(\\d{1,2})\(ordinal)\\s+(?:of\\s+)?(\(monthAlt))\\.?(?:,?\\s+(\\d{4}))?") { g in
            guard let m = index(of: g[2], in: lx.months), let d = Int(g[1] ?? "") else { return nil }
            return .monthDay(month: m + 1, day: d, year: g[3].flatMap { Int($0) })
        }
        add("the\\s+(\\d{1,2})(?:st|nd|rd|th)") { g in Int(g[1] ?? "").map { .dayOfMonth($0) } }

        // ISO and numeric dates
        add("(\\d{4})-(\\d{1,2})-(\\d{1,2})") { g in
            guard let y = Int(g[1] ?? ""), let m = Int(g[2] ?? ""), let d = Int(g[3] ?? "") else { return nil }
            return .monthDay(month: m, day: d, year: y)
        }
        add("(\\d{1,2})/(\\d{1,2})(?:/(\\d{2,4}))?") { g in
            guard let a = Int(g[1] ?? ""), let b = Int(g[2] ?? "") else { return nil }
            var year = g[3].flatMap { Int($0) }
            if let y = year, y < 100 { year = 2000 + y }
            return .numericDate(first: a, second: b, year: year)
        }
        add("(\\d{1,2})\\.(\\d{1,2})\\.(\\d{4})") { g in
            guard let a = Int(g[1] ?? ""), let b = Int(g[2] ?? "") else { return nil }
            return .numericDate(first: a, second: b, year: Int(g[3] ?? ""))
        }

        // Relative offsets: "in 3 days", "in a week", "in two hours"
        let inAlt = alt(lx.inWord)
        let amount = "(\\d{1,3}|\(oneAlt)|\(numberAlt))"
        let units: [([String], (Int) -> DateComponent)] = [
            (lx.dayUnits, { .offsetDays($0) }),
            (lx.weekUnits, { .offsetDays($0 * 7) }),
            (lx.monthUnits, { .offsetMonths($0) }),
            (lx.hourUnits, { .offsetMinutes($0 * 60) }),
            (lx.minuteUnits, { .offsetMinutes($0) }),
        ]
        for (unitWords, make) in units where !unitWords.isEmpty {
            add("(?:\(inAlt))\\s+\(amount)\\s+(?:\(alt(unitWords)))") { g in number(g[1]).map(make) }
            add("\(amount)\\s+(?:\(alt(unitWords)))\\s+from\\s+(?:now|today)") { g in number(g[1]).map(make) }
        }
        if lx.languageCode == "en" {
            fixed(["in a fortnight", "in two weeks time"], .offsetDays(14))
            fixed(["a week from today", "a week from now", "this time next week"], .offsetDays(7))
        }

        // Clock times
        let timePrep = alt(lx.timePrepositions)
        add("(?:\(timePrep))\\s+(\\d{1,2})(?::(\\d{2}))?\\s*\(meridiem)?(?:\\s*o['’]?clock)?") { g in
            guard let h = Int(g[1] ?? ""), h <= 24 else { return nil }
            let minute = Int(g[2] ?? "") ?? 0
            guard minute < 60 else { return nil }
            return .clock(hour: h % 24, minute: minute, meridiem: meridiemValue(g[3]))
        }
        add("(\\d{1,2}):(\\d{2})\\s*\(meridiem)?") { g in
            guard let h = Int(g[1] ?? ""), let m = Int(g[2] ?? ""), h <= 24, m < 60 else { return nil }
            return .clock(hour: h % 24, minute: m, meridiem: meridiemValue(g[3]))
        }
        add("(\\d{1,2})\\s*\(meridiem)") { g in
            guard let h = Int(g[1] ?? ""), (1...12).contains(h) else { return nil }
            return .clock(hour: h, minute: 0, meridiem: meridiemValue(g[2]))
        }
        add("(?:(?:\(timePrep))\\s+)?(\(numberAlt))(?:\\s+o['’]?clock)?(?:\\s*\(meridiem))?") { g in
            // Bare number words only count as times after a time preposition or with a marker.
            let whole = (g[0] ?? "").lowercased()
            let hasPrep = lx.timePrepositions.contains { whole.hasPrefix($0 + " ") }
            guard hasPrep || g[2] != nil || whole.contains("clock"), let h = number(g[1]) else { return nil }
            return .clock(hour: h, minute: 0, meridiem: meridiemValue(g[2]))
        }
        if lx.languageCode == "pl" {
            add("o\\s+(?:godzinie\\s+)?(\\d{1,2})(?::(\\d{2}))?") { g in
                guard let h = Int(g[1] ?? ""), h < 24 else { return nil }
                return .clock(hour: h, minute: Int(g[2] ?? "") ?? 0, meridiem: nil)
            }
        }
        return rules
    }
}
