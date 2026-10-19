import Foundation

/// Why a resolved date needs the user's attention.
public enum DateAmbiguityKind: String, Codable, Hashable, Sendable {
    /// "At 4" without am/pm.
    case meridiem
    /// "Friday" said on a Friday.
    case sameWeekday
    /// "Next Thursday" could mean two different dates.
    case nextWeekday
    /// "05/06" could be 5 June or May 6.
    case numericDateOrder
    /// The resolved deadline is already in the past.
    case pastDate
    /// A time was assumed from a vague word ("tonight", "morning").
    case assumedTime
    /// The day was assumed ("at 4" → today or tomorrow).
    case assumedDay
    /// "End of day" with no configured end-of-day time; kept date-only.
    case endOfDayUnspecified
    /// Daylight-saving gap: that local time does not exist.
    case nonexistentLocalTime
    /// Daylight-saving overlap: that local time happens twice.
    case repeatedLocalTime
    /// The phrase names an event, not a date.
    case eventLinked
    /// The phrase is a period, not a deadline.
    case approximatePeriod
    /// Nothing in the phrase could be interpreted as a date.
    case unrecognized
    /// The date does not exist (e.g. 31 February).
    case invalidDate

    /// Ambiguities that must be confirmed before saving.
    public var requiresConfirmation: Bool {
        switch self {
        case .meridiem, .nextWeekday, .numericDateOrder, .pastDate, .nonexistentLocalTime,
             .repeatedLocalTime, .invalidDate:
            return true
        case .sameWeekday, .assumedTime, .assumedDay, .endOfDayUnspecified, .eventLinked, .approximatePeriod, .unrecognized:
            return false
        }
    }
}

public struct DateAmbiguity: Codable, Hashable, Sendable {
    public var kind: DateAmbiguityKind
    public var message: String
    public init(_ kind: DateAmbiguityKind, _ message: String) {
        self.kind = kind
        self.message = message
    }
}

/// One possible interpretation of a deadline phrase.
public struct DueCandidate: Codable, Hashable, Sendable {
    public var due: Commitment.Due
    /// Absolute instant (start of window/day for date-only values).
    public var resolvedAt: Date?

    public init(due: Commitment.Due, resolvedAt: Date?) {
        self.due = due
        self.resolvedAt = resolvedAt
    }
}

public struct DateResolution: Codable, Hashable, Sendable {
    public var phrase: String?
    /// First candidate is the proposal; others are offered as quick corrections.
    public var candidates: [DueCandidate]
    public var ambiguities: [DateAmbiguity]

    public var proposed: DueCandidate? { candidates.first }
    public var needsConfirmation: Bool { ambiguities.contains { $0.kind.requiresConfirmation } }

    public static func unscheduled(phrase: String?, ambiguities: [DateAmbiguity] = []) -> DateResolution {
        DateResolution(phrase: phrase, candidates: [], ambiguities: ambiguities)
    }
}

/// Deterministic interpretation of deadline phrases. The AI may *find* a phrase;
/// only this code decides what date it means (PRD §3.3, §8.4).
public struct DateResolver: Sendable {
    public var calendar: Calendar
    public var locale: Locale
    public var preferences: DateInterpretationPreferences
    public var scanner: DatePhraseScanner

    public init(calendar: Calendar = .current, locale: Locale = .current,
                preferences: DateInterpretationPreferences = DateInterpretationPreferences(),
                lexicon: DateLexicon? = nil) {
        var cal = calendar
        cal.locale = locale
        self.calendar = cal
        self.locale = locale
        self.preferences = preferences
        self.scanner = DatePhraseScanner(lexicon: lexicon ?? DateLexicon.forLanguage(locale.language.languageCode?.identifier))
    }

    public func resolve(_ phrase: String?, anchor: Date) -> DateResolution {
        guard let phrase = phrase?.trimmingCharacters(in: .whitespacesAndNewlines), !phrase.isEmpty else {
            return .unscheduled(phrase: nil)
        }
        let components = scanner.components(in: phrase)
        return resolve(components: components, phrase: phrase, anchor: anchor)
    }

    // MARK: Resolution

    private struct DayChoice {
        var local: LocalDateTime
        var windowEnd: LocalDateTime?
        var precision: DuePrecision
    }

    public func resolve(components: [DateComponent], phrase: String, anchor: Date) -> DateResolution {
        let tzId = calendar.timeZone.identifier
        guard !components.isEmpty else {
            return .unscheduled(phrase: phrase, ambiguities: [DateAmbiguity(.unrecognized, "Couldn’t read a date from “\(phrase)”. Pick one or leave it unscheduled.")])
        }
        var notes: [DateAmbiguity] = []
        let today = LocalDateTime(anchor, calendar: calendar, includeTime: false)

        let dayComponent = components.first { !$0.isTime }
        let timeComponents = components.filter(\.isTime)

        // Non-date phrases first.
        if case .eventLinked = dayComponent {
            return DateResolution(phrase: phrase, candidates: [DueCandidate(due: Commitment.Due(precision: .eventLinked, timezoneId: tzId, phrase: phrase), resolvedAt: nil)],
                                  ambiguities: [DateAmbiguity(.eventLinked, "Linked to an event, not a date. Add a date if you want a reminder.")])
        }
        if case .vague = dayComponent, timeComponents.isEmpty {
            return DateResolution(phrase: phrase, candidates: [DueCandidate(due: Commitment.Due(precision: .approximate, timezoneId: tzId, phrase: phrase), resolvedAt: nil)],
                                  ambiguities: [DateAmbiguity(.approximatePeriod, "“\(phrase)” has no specific date. Kept unscheduled.")])
        }

        // Pure relative time offsets ("in 2 hours") resolve to an exact instant.
        if case let .offsetMinutes(minutes)? = timeComponents.first, dayComponent == nil {
            let date = anchor.addingTimeInterval(TimeInterval(minutes * 60))
            let local = LocalDateTime(date, calendar: calendar)
            return DateResolution(phrase: phrase, candidates: [candidate(local, precision: .datetime, windowEnd: nil, phrase: phrase)], ambiguities: [])
        }

        // Day alternatives.
        var days: [DayChoice] = []
        switch dayComponent {
        case .none:
            days = [] // decided after the time is known
        case .today?, .tonight?:
            days = [DayChoice(local: today, precision: .day)]
        case .tomorrow?:
            days = [DayChoice(local: today.addingDays(1, calendar: calendar), precision: .day)]
        case .dayAfterTomorrow?:
            days = [DayChoice(local: today.addingDays(2, calendar: calendar), precision: .day)]
        case let .weekday(weekday, modifier)?:
            days = weekdayChoices(weekday, modifier: modifier, today: today, anchor: anchor, notes: &notes)
        case let .monthDay(month, day, year)?:
            guard let local = explicitDate(month: month, day: day, year: year, today: today, notes: &notes) else {
                return .unscheduled(phrase: phrase, ambiguities: notes)
            }
            days = [DayChoice(local: local, precision: .day)]
        case let .numericDate(first, second, year)?:
            days = numericChoices(first, second, year: year, today: today, notes: &notes)
            if days.isEmpty { return .unscheduled(phrase: phrase, ambiguities: notes) }
        case let .dayOfMonth(d)?:
            var month = today.month, year = today.year
            if d < today.day { month += 1; if month > 12 { month = 1; year += 1 } }
            guard let local = validDate(year: year, month: month, day: d) else {
                return .unscheduled(phrase: phrase, ambiguities: [DateAmbiguity(.invalidDate, "That day doesn’t exist in that month.")])
            }
            days = [DayChoice(local: local, precision: .day)]
        case let .offsetDays(n)?:
            days = [DayChoice(local: today.addingDays(n, calendar: calendar), precision: .day)]
        case let .offsetMonths(n)?:
            let start = today.startOfDay(in: calendar) ?? anchor
            let shifted = calendar.date(byAdding: .month, value: n, to: start) ?? start
            days = [DayChoice(local: LocalDateTime(shifted, calendar: calendar, includeTime: false), precision: .day)]
        case let .window(window)?:
            days = windowChoices(window, today: today, notes: &notes)
            notes.append(DateAmbiguity(.approximatePeriod, "“\(phrase)” is a period, not a deadline. You’ll get a check-in, not an overdue alert."))
        case .endOfMonth?:
            days = [DayChoice(local: lastDayOfMonth(containing: today), precision: .day)]
        case .vague?:
            days = []
        case .eventLinked?:
            days = []
        default:
            days = []
        }

        // Time.
        let timeResult = interpretTime(timeComponents, hasDay: dayComponent != nil, isTonight: dayComponent == .tonight, notes: &notes)

        // A time with no day: today if still ahead, otherwise tomorrow.
        if days.isEmpty, timeResult.isEmpty, timeComponents.contains(.endOfDay) {
            days = [DayChoice(local: today, precision: .day)]
        }
        if days.isEmpty {
            guard let first = timeResult.first else {
                return .unscheduled(phrase: phrase, ambiguities: notes)
            }
            let todayAt = today.with(hour: first.hour, minute: first.minute)
            let todayInstant = WallClock.resolve(todayAt, calendar: calendar)?.date ?? anchor
            let day = todayInstant > anchor ? today : today.addingDays(1, calendar: calendar)
            days = [DayChoice(local: day, precision: .day)]
            if !(dayComponent == .tonight) {
                let label = day == today ? "today" : "tomorrow"
                notes.append(DateAmbiguity(.assumedDay, "No day was given, so this is set for \(label)."))
            }
        }

        // Combine: primary day × all time options, then alternative days × primary time.
        var candidates: [DueCandidate] = []
        let primary = days[0]
        if timeResult.isEmpty || primary.precision == .approximate {
            for d in days { candidates.append(candidate(d.local, precision: d.precision, windowEnd: d.windowEnd, phrase: phrase)) }
        } else {
            for t in timeResult {
                candidates.append(candidate(primary.local.with(hour: t.hour, minute: t.minute), precision: .datetime, windowEnd: nil, phrase: phrase))
            }
            for d in days.dropFirst() {
                candidates.append(candidate(d.local.with(hour: timeResult[0].hour, minute: timeResult[0].minute), precision: .datetime, windowEnd: nil, phrase: phrase))
            }
        }

        // DST checks on the proposal.
        if let first = candidates.first, let local = first.due.local, local.hasTime,
           let wall = WallClock.resolve(local, calendar: calendar), let anomaly = wall.anomaly {
            switch anomaly {
            case .nonexistent:
                notes.append(DateAmbiguity(.nonexistentLocalTime, "That time is skipped by a daylight-saving change; it will be moved forward."))
            case .repeated:
                notes.append(DateAmbiguity(.repeatedLocalTime, "That time happens twice because of a daylight-saving change; the first one is used."))
            }
        }

        // Past check on the proposal.
        if let first = candidates.first, first.due.precision != .approximate {
            let isPast: Bool
            if first.due.precision == .datetime {
                isPast = (first.resolvedAt ?? anchor) < anchor
            } else {
                isPast = (first.due.local ?? today) < today
            }
            if isPast {
                notes.append(DateAmbiguity(.pastDate, "That date has already passed. Confirm it or choose a new one."))
            }
        }

        return DateResolution(phrase: phrase, candidates: dedupe(candidates), ambiguities: notes)
    }

    // MARK: Helpers

    private func candidate(_ local: LocalDateTime, precision: DuePrecision, windowEnd: LocalDateTime?, phrase: String) -> DueCandidate {
        let resolved = WallClock.resolve(local, calendar: calendar)?.date
        return DueCandidate(due: Commitment.Due(precision: precision, local: local, windowEnd: windowEnd,
                                                timezoneId: calendar.timeZone.identifier, phrase: phrase),
                            resolvedAt: resolved)
    }

    private func dedupe(_ list: [DueCandidate]) -> [DueCandidate] {
        var seen = Set<String>()
        return list.filter { c in
            let key = (c.due.local?.isoString ?? "-") + c.due.precision.rawValue
            return seen.insert(key).inserted
        }
    }

    private func validDate(year: Int, month: Int, day: Int) -> LocalDateTime? {
        guard (1...12).contains(month), (1...31).contains(day),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == year, back.month == month, back.day == day else { return nil }
        return LocalDateTime(year: year, month: month, day: day)
    }

    private func explicitDate(month: Int, day: Int, year: Int?, today: LocalDateTime, notes: inout [DateAmbiguity]) -> LocalDateTime? {
        if let year {
            guard let d = validDate(year: year, month: month, day: day) else {
                notes.append(DateAmbiguity(.invalidDate, "That date doesn’t exist."))
                return nil
            }
            return d
        }
        guard var d = validDate(year: today.year, month: month, day: day) ?? validDate(year: today.year + 1, month: month, day: day) else {
            notes.append(DateAmbiguity(.invalidDate, "That date doesn’t exist."))
            return nil
        }
        // Without a year, a date more than 30 days back means next year; a recent
        // past date is kept (and flagged) because the user may be logging a late promise.
        if d < today, let dStart = d.startOfDay(in: calendar), let tStart = today.startOfDay(in: calendar),
           tStart.timeIntervalSince(dStart) > 30 * 86400,
           let next = validDate(year: today.year + 1, month: month, day: day) {
            d = next
        }
        return d
    }

    private func numericChoices(_ a: Int, _ b: Int, year: Int?, today: LocalDateTime, notes: inout [DateAmbiguity]) -> [DayChoice] {
        let monthFirstRegions: Set<String> = ["US", "PH", "FM", "MH", "PW", "BZ"]
        let monthFirst = monthFirstRegions.contains(locale.region?.identifier ?? "")
        var ignored: [DateAmbiguity] = []
        func make(month: Int, day: Int) -> LocalDateTime? {
            explicitDate(month: month, day: day, year: year, today: today, notes: &ignored)
        }
        let dayFirst = make(month: b, day: a)
        let mFirst = make(month: a, day: b)
        var ordered: [LocalDateTime] = []
        if a > 12 { if let dayFirst { ordered = [dayFirst] } }
        else if b > 12 { if let mFirst { ordered = [mFirst] } }
        else {
            ordered = (monthFirst ? [mFirst, dayFirst] : [dayFirst, mFirst]).compactMap { $0 }
            if a != b, ordered.count == 2 {
                notes.append(DateAmbiguity(.numericDateOrder, "“\(a)/\(b)” could be read two ways. Check the date."))
            }
        }
        if ordered.isEmpty { notes.append(DateAmbiguity(.invalidDate, "That date doesn’t exist.")) }
        return ordered.map { DayChoice(local: $0, precision: .day) }
    }

    private func weekdayChoices(_ weekday: Int, modifier: DateComponent.WeekdayModifier, today: LocalDateTime,
                                anchor: Date, notes: inout [DateAmbiguity]) -> [DayChoice] {
        let anchorWeekday = calendar.component(.weekday, from: today.startOfDay(in: calendar) ?? anchor)
        let delta = (weekday - anchorWeekday + 7) % 7
        let name = calendar.weekdaySymbols[weekday - 1]
        switch modifier {
        case .none, .this:
            if delta == 0 {
                let todayChoice = DayChoice(local: today, precision: .day)
                let nextChoice = DayChoice(local: today.addingDays(7, calendar: calendar), precision: .day)
                if preferences.sameWeekdayPolicy == .today {
                    notes.append(DateAmbiguity(.sameWeekday, "Today is \(name), so this means today. Next \(name) is one tap away."))
                    return [todayChoice, nextChoice]
                } else {
                    notes.append(DateAmbiguity(.sameWeekday, "Today is \(name), so this means \(name) next week."))
                    return [nextChoice, todayChoice]
                }
            }
            return [DayChoice(local: today.addingDays(delta, calendar: calendar), precision: .day)]
        case .next:
            let nearest = delta == 0 ? 7 : delta
            let nearestDay = today.addingDays(nearest, calendar: calendar)
            let followingDay = weekdayInNextCalendarWeek(weekday, today: today) ?? nearestDay
            if nearestDay == followingDay {
                return [DayChoice(local: nearestDay, precision: .day)]
            }
            switch preferences.nextWeekdayPolicy {
            case .nearest:
                return [DayChoice(local: nearestDay, precision: .day), DayChoice(local: followingDay, precision: .day)]
            case .followingWeek:
                return [DayChoice(local: followingDay, precision: .day), DayChoice(local: nearestDay, precision: .day)]
            case .ask:
                notes.append(DateAmbiguity(.nextWeekday, "“Next \(name)” can mean two dates. Pick the one you meant."))
                return [DayChoice(local: followingDay, precision: .day), DayChoice(local: nearestDay, precision: .day)]
            }
        }
    }

    private func weekInterval(containing local: LocalDateTime) -> (start: LocalDateTime, end: LocalDateTime)? {
        guard let start = local.startOfDay(in: calendar),
              let interval = calendar.dateInterval(of: .weekOfYear, for: start) else { return nil }
        let s = LocalDateTime(interval.start, calendar: calendar, includeTime: false)
        let e = LocalDateTime(interval.end.addingTimeInterval(-1), calendar: calendar, includeTime: false)
        return (s, e)
    }

    private func weekdayInNextCalendarWeek(_ weekday: Int, today: LocalDateTime) -> LocalDateTime? {
        guard let thisWeek = weekInterval(containing: today) else { return nil }
        let nextStart = thisWeek.start.addingDays(7, calendar: calendar)
        for offset in 0..<7 {
            let d = nextStart.addingDays(offset, calendar: calendar)
            if let s = d.startOfDay(in: calendar), calendar.component(.weekday, from: s) == weekday { return d }
        }
        return nil
    }

    private func lastDayOfMonth(containing local: LocalDateTime) -> LocalDateTime {
        guard let start = local.startOfDay(in: calendar),
              let interval = calendar.dateInterval(of: .month, for: start) else { return local }
        return LocalDateTime(interval.end.addingTimeInterval(-1), calendar: calendar, includeTime: false)
    }

    private func windowChoices(_ window: DateComponent.Window, today: LocalDateTime, notes: inout [DateAmbiguity]) -> [DayChoice] {
        func approx(_ s: LocalDateTime, _ e: LocalDateTime) -> DayChoice { DayChoice(local: s, windowEnd: e, precision: .approximate) }
        let weekday = calendar.component(.weekday, from: today.startOfDay(in: calendar) ?? Date())
        func upcomingWeekend() -> (LocalDateTime, LocalDateTime) {
            if weekday == 7 { return (today, today.addingDays(1, calendar: calendar)) }
            if weekday == 1 { return (today, today) }
            let toSat = 7 - weekday
            let sat = today.addingDays(toSat, calendar: calendar)
            return (sat, sat.addingDays(1, calendar: calendar))
        }
        switch window {
        case .thisWeek:
            guard let w = weekInterval(containing: today) else { return [] }
            return [approx(today, w.end)]
        case .nextWeek:
            guard let w = weekInterval(containing: today.addingDays(7, calendar: calendar)) else { return [] }
            return [approx(w.start, w.end)]
        case .thisWeekend:
            let (s, e) = upcomingWeekend()
            return [approx(s, e)]
        case .nextWeekend:
            let (s, e) = upcomingWeekend()
            let following = approx(s.addingDays(7, calendar: calendar), e.addingDays(7, calendar: calendar))
            // On weekdays "next weekend" is dialect-dependent, like "next Friday".
            if weekday != 1 && weekday != 7 && preferences.nextWeekdayPolicy == .ask {
                notes.append(DateAmbiguity(.nextWeekday, "“Next weekend” can mean two weekends. Pick the one you meant."))
                return [following, approx(s, e)]
            }
            return [following]
        case .thisMonth:
            return [approx(today, lastDayOfMonth(containing: today))]
        case .nextMonth:
            let start = today.startOfDay(in: calendar) ?? Date()
            let next = calendar.date(byAdding: .month, value: 1, to: start) ?? start
            let nextLocal = LocalDateTime(next, calendar: calendar, includeTime: false)
            let first = LocalDateTime(year: nextLocal.year, month: nextLocal.month, day: 1)
            return [approx(first, lastDayOfMonth(containing: first))]
        case .coupleOfDays:
            return [approx(today.addingDays(1, calendar: calendar), today.addingDays(3, calendar: calendar))]
        case .fewDays:
            return [approx(today.addingDays(2, calendar: calendar), today.addingDays(5, calendar: calendar))]
        }
    }

    private struct Clock { var hour: Int; var minute: Int }

    /// Returns time options (first = proposal) or empty for date-only.
    private func interpretTime(_ parts: [DateComponent], hasDay: Bool, isTonight: Bool, notes: inout [DateAmbiguity]) -> [Clock] {
        var periodHint: DateComponent.Meridiem? = isTonight ? .pm : nil
        var periodTime: TimeOfDay?
        for p in parts {
            switch p {
            case .morning: periodHint = .am; periodTime = preferences.morningTime
            case .afternoon: periodHint = .pm; periodTime = preferences.afternoonTime
            case .evening: periodHint = .pm; periodTime = preferences.eveningTime
            default: break
            }
        }
        if isTonight && periodTime == nil { periodTime = preferences.eveningTime }

        if let clock = parts.compactMap({ p -> (Int, Int, DateComponent.Meridiem?)? in
            if case let .clock(h, m, mer) = p { return (h, m, mer) } else { return nil }
        }).first {
            let (h, m, mer) = clock
            if let mer = mer ?? (h >= 1 && h <= 12 ? periodHint : nil) {
                let hour = mer == .pm ? (h % 12) + 12 : (h % 12)
                return [Clock(hour: hour, minute: m)]
            }
            if h == 0 || h >= 13 { return [Clock(hour: h, minute: m)] }
            // Ambiguous 12-hour clock: assume business hours, offer the other half.
            let pm = Clock(hour: h == 12 ? 12 : h + 12, minute: m)
            let am = Clock(hour: h == 12 ? 0 : h, minute: m)
            let preferPM = (1...7).contains(h) || h == 12
            let primary = preferPM ? pm : am
            let other = preferPM ? am : pm
            notes.append(DateAmbiguity(.meridiem, "“\(h)\(m == 0 ? "" : String(format: ":%02d", m))” could be morning or afternoon. Showing \(String(format: "%02d:%02d", primary.hour, primary.minute))."))
            return [primary, other]
        }
        if parts.contains(.noon) { return [Clock(hour: 12, minute: 0)] }
        if parts.contains(.midnight) {
            notes.append(DateAmbiguity(.assumedTime, "“Midnight” is treated as the end of that day (23:59)."))
            return [Clock(hour: 23, minute: 59)]
        }
        if parts.contains(.endOfDay) {
            if let eod = preferences.endOfDayTime { return [Clock(hour: eod.hour, minute: eod.minute)] }
            notes.append(DateAmbiguity(.endOfDayUnspecified, "“End of day” kept as a date. Set an end-of-day time in Settings to make it exact."))
            return []
        }
        if let t = periodTime {
            notes.append(DateAmbiguity(.assumedTime, "No exact time was given; using \(String(format: "%02d:%02d", t.hour, t.minute))."))
            return [Clock(hour: t.hour, minute: t.minute)]
        }
        return []
    }
}
