import Foundation

/// Human-readable deadline text that respects the user's locale (12/24-hour clock,
/// date order) and never hides that a deadline is approximate.
public struct DueFormatter: Sendable {
    public var calendar: Calendar
    public var locale: Locale

    public init(calendar: Calendar = .current, locale: Locale = .current) {
        self.calendar = calendar
        self.locale = locale
    }

    private func formatter(_ template: String, timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar
        f.timeZone = timeZone
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }

    /// "Thu, 23 Oct 2026" or "Thu, 23 Oct 2026, 16:00".
    public func absolute(_ local: LocalDateTime, timeZone: TimeZone) -> String {
        var cal = calendar
        cal.timeZone = timeZone
        guard let date = WallClock.resolve(local, calendar: cal)?.date else { return local.isoString }
        return formatter(local.hasTime ? "EEE d MMM y jmm" : "EEE d MMM y", timeZone: timeZone).string(from: date)
    }

    /// Long form for confirmations: "Thursday, 23 Oct 2026".
    public func longDay(_ local: LocalDateTime, timeZone: TimeZone) -> String {
        var cal = calendar
        cal.timeZone = timeZone
        guard let date = local.startOfDay(in: cal) else { return local.isoString }
        return formatter("EEEE d MMM y", timeZone: timeZone).string(from: date)
    }

    public func time(_ local: LocalDateTime, timeZone: TimeZone) -> String? {
        guard local.hasTime else { return nil }
        var cal = calendar
        cal.timeZone = timeZone
        guard let date = WallClock.resolve(local, calendar: cal)?.date else { return nil }
        return formatter("jmm", timeZone: timeZone).string(from: date)
    }

    /// Relative label for list rows: "Today, 5:00 PM", "Tomorrow", "Thu, 23 Oct", "Next week".
    public func short(_ c: Commitment, now: Date) -> String {
        short(due: c.due, now: now)
    }

    public func short(due: Commitment.Due, now: Date) -> String {
        let tz = TimeZone(identifier: due.timezoneId) ?? calendar.timeZone
        switch due.precision {
        case .none:
            return "No date"
        case .eventLinked:
            return due.phrase.map { capitalizeFirst($0) } ?? "Linked to an event"
        case .approximate, .relative:
            if let phrase = due.phrase { return capitalizeFirst(stripPreposition(phrase)) }
            guard let local = due.local else { return "Sometime" }
            let start = dayLabel(local, timeZone: tz, now: now)
            if let end = due.windowEnd, end != local { return "\(start) – \(dayLabel(end, timeZone: tz, now: now))" }
            return start
        case .day, .datetime:
            guard let local = due.local else { return "No date" }
            let day = dayLabel(local, timeZone: tz, now: now)
            var text = day
            if let t = time(local, timeZone: tz) { text += ", \(t)" }
            if tz.identifier != calendar.timeZone.identifier, let abbr = tz.abbreviation() { text += " \(abbr)" }
            return text
        }
    }

    public func dayLabel(_ local: LocalDateTime, timeZone: TimeZone, now: Date) -> String {
        var cal = calendar
        cal.timeZone = timeZone
        let today = LocalDateTime(now, calendar: cal, includeTime: false)
        let day = local.dateOnly
        if day == today { return "Today" }
        if day == today.addingDays(1, calendar: cal) { return "Tomorrow" }
        if day == today.addingDays(-1, calendar: cal) { return "Yesterday" }
        guard let date = day.startOfDay(in: cal) else { return day.isoString }
        let sameYear = day.year == today.year
        return formatter(sameYear ? "EEE d MMM" : "EEE d MMM y", timeZone: timeZone).string(from: date)
    }

    private func stripPreposition(_ s: String) -> String {
        let lowered = s.lowercased()
        for p in ["by ", "on ", "before ", "until ", "no later than "] where lowered.hasPrefix(p) {
            return String(s.dropFirst(p.count))
        }
        return s
    }

    private func capitalizeFirst(_ s: String) -> String {
        guard let f = s.first else { return s }
        return f.uppercased() + s.dropFirst()
    }
}
