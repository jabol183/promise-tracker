import Foundation

public enum SmartFilter: String, CaseIterable, Codable, Hashable, Sendable {
    case all, needsAttention, overdue, today, thisWeek, upcoming, waiting, unscheduled, completed

    public var title: String {
        switch self {
        case .all: return "All"
        case .needsAttention: return "Needs attention"
        case .overdue: return "Overdue"
        case .today: return "Today"
        case .thisWeek: return "This week"
        case .upcoming: return "Upcoming"
        case .waiting: return "Waiting"
        case .unscheduled: return "Unscheduled"
        case .completed: return "Completed"
        }
    }
}

/// Where a commitment belongs right now. Computed, never stored.
public enum CommitmentBucket: Int, Comparable, Hashable, Sendable {
    case overdue = 0, dueToday, tomorrow, thisWeek, later, approximate, waiting, unscheduled, closed

    public static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }

    public var sectionTitle: String {
        switch self {
        case .overdue: return "Overdue"
        case .dueToday: return "Due today"
        case .tomorrow: return "Tomorrow"
        case .thisWeek: return "This week"
        case .later: return "Later"
        case .approximate: return "Planned"
        case .waiting: return "Waiting"
        case .unscheduled: return "Unscheduled"
        case .closed: return "Done"
        }
    }
}

public struct CommitmentClassifier: Sendable {
    public var calendar: Calendar
    public init(calendar: Calendar = .current) { self.calendar = calendar }

    /// Only hard deadlines can be overdue; approximate periods and waiting items never are.
    public func isOverdue(_ c: Commitment, now: Date) -> Bool {
        guard c.status == .open, c.duePrecision.isHardDeadline, let local = c.dueLocal else { return false }
        let cal = c.calendar(base: calendar)
        if c.duePrecision == .datetime {
            return (WallClock.resolve(local, calendar: cal)?.date ?? .distantFuture) < now
        }
        // Date-only: overdue once that whole day has passed in the deadline's zone.
        guard let start = local.startOfDay(in: cal), let end = cal.date(byAdding: .day, value: 1, to: start) else { return false }
        return end <= now
    }

    /// Plain-language reason shown wherever the app says "overdue" (FR-06).
    public func overdueReason(_ c: Commitment, now: Date, locale: Locale = .current) -> String? {
        guard isOverdue(c, now: now), let local = c.dueLocal else { return nil }
        let formatter = DueFormatter(calendar: calendar, locale: locale)
        let due = formatter.absolute(local, timeZone: c.timeZone)
        let cal = c.calendar(base: calendar)
        let todayStart = calendar.startOfDay(for: now)
        let dueStart = local.startOfDay(in: cal) ?? now
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: dueStart), to: todayStart).day ?? 0
        let ago: String
        if c.duePrecision == .datetime && days == 0 { ago = "earlier today" }
        else if days <= 1 { ago = days == 1 ? "yesterday" : "today" }
        else { ago = "\(days) days ago" }
        let phrase = c.agreedDueText.map { " You said “\($0)”." } ?? ""
        return "Was due \(due) (\(ago)).\(phrase)"
    }

    public func bucket(_ c: Commitment, now: Date) -> CommitmentBucket {
        if c.status.isClosed || c.status == .archived { return .closed }
        if c.status == .waiting { return .waiting }
        if isOverdue(c, now: now) { return .overdue }
        guard let local = c.dueLocal else { return .unscheduled }
        if c.duePrecision == .approximate { return .approximate }
        guard c.duePrecision.isHardDeadline else { return .unscheduled }
        let today = LocalDateTime(now, calendar: c.calendar(base: calendar), includeTime: false)
        let day = local.dateOnly
        if day == today { return .dueToday }
        if day == today.addingDays(1, calendar: c.calendar(base: calendar)) { return .tomorrow }
        if let week = calendar.dateInterval(of: .weekOfYear, for: now), let due = c.dueAt, due < week.end { return .thisWeek }
        return .later
    }

    public func matches(_ c: Commitment, filter: SmartFilter, now: Date) -> Bool {
        let b = bucket(c, now: now)
        switch filter {
        case .all: return c.status.isActive
        case .needsAttention: return b == .overdue || b == .dueToday || (c.requiresReview && c.status.isActive)
        case .overdue: return b == .overdue
        case .today: return b == .dueToday
        case .thisWeek: return [.dueToday, .tomorrow, .thisWeek].contains(b) || (b == .approximate && windowOverlapsThisWeek(c, now: now))
        case .upcoming: return [.dueToday, .tomorrow, .thisWeek, .later, .approximate].contains(b)
        case .waiting: return b == .waiting
        case .unscheduled: return b == .unscheduled
        case .completed: return c.status == .completed
        }
    }

    private func windowOverlapsThisWeek(_ c: Commitment, now: Date) -> Bool {
        guard let start = c.dueAt, let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return false }
        return start < week.end
    }

    /// Sort order inside lists: bucket, then deadline, then pinned, then newest.
    public func sorted(_ list: [Commitment], now: Date) -> [Commitment] {
        list.sorted { a, b in
            let ba = bucket(a, now: now), bb = bucket(b, now: now)
            if ba != bb { return ba < bb }
            if a.isPinned != b.isPinned { return a.isPinned }
            switch (a.dueAt, b.dueAt) {
            case let (x?, y?) where x != y: return x < y
            case (.some, .none): return true
            case (.none, .some): return false
            default: return a.createdAt > b.createdAt
            }
        }
    }
}

/// Deterministic counts for the briefing (PRD Journey F). No model needed.
public struct DigestSummary: Equatable, Sendable {
    public var dueToday: Int
    public var overdue: Int
    public var waiting: Int
    public var dueThisWeek: Int
    public var unscheduled: Int

    public var hasAnything: Bool { dueToday + overdue + waiting > 0 }

    public var sentence: String {
        func n(_ count: Int, _ one: String, _ many: String) -> String { "\(count) \(count == 1 ? one : many)" }
        var parts: [String] = []
        if dueToday > 0 { parts.append("\(n(dueToday, "promise", "promises")) due today") }
        if overdue > 0 { parts.append("\(overdue) overdue") }
        if waiting > 0 { parts.append("\(waiting) waiting for \(waiting == 1 ? "a response" : "responses")") }
        guard !parts.isEmpty else { return "Nothing due today." }
        let list: String
        if parts.count == 1 { list = parts[0] }
        else { list = parts.dropLast().joined(separator: ", ") + " and " + parts.last! }
        // "1 overdue" alone reads oddly without a noun.
        if parts.count == 1 && overdue > 0 { return "You have \(n(overdue, "promise", "promises")) overdue." }
        return "You have \(list)."
    }

    /// Short header line: "2 due today · 1 overdue".
    public var headline: String {
        var parts: [String] = []
        if dueToday > 0 { parts.append("\(dueToday) due today") }
        if overdue > 0 { parts.append("\(overdue) overdue") }
        if waiting > 0 { parts.append("\(waiting) waiting") }
        return parts.isEmpty ? "You’re all caught up" : parts.joined(separator: " · ")
    }
}

public struct DigestBuilder: Sendable {
    public var calendar: Calendar
    public init(calendar: Calendar = .current) { self.calendar = calendar }

    public func summary(_ list: [Commitment], now: Date) -> DigestSummary {
        let cls = CommitmentClassifier(calendar: calendar)
        var s = DigestSummary(dueToday: 0, overdue: 0, waiting: 0, dueThisWeek: 0, unscheduled: 0)
        for c in list where c.status.isActive {
            switch cls.bucket(c, now: now) {
            case .dueToday: s.dueToday += 1; s.dueThisWeek += 1
            case .overdue: s.overdue += 1
            case .waiting: s.waiting += 1
            case .tomorrow, .thisWeek: s.dueThisWeek += 1
            case .unscheduled: s.unscheduled += 1
            default: break
            }
        }
        return s
    }
}

/// "Your impact" numbers. Counts only — no invented productivity score.
public struct ImpactStats: Equatable, Sendable {
    public enum Period: String, CaseIterable, Sendable { case week, month, year }

    public var total: Int
    public var completed: Int
    public var completedOnTime: Int
    public var overdue: Int
    public var upcoming: Int
    public var cancelled: Int

    /// Completed share of promises that were not cancelled; nil when there's nothing yet.
    public var keptRate: Double? {
        let denominator = total - cancelled
        return denominator > 0 ? Double(completed) / Double(denominator) : nil
    }

    public static func compute(_ list: [Commitment], period: Period, now: Date, calendar: Calendar) -> ImpactStats {
        let component: Calendar.Component = period == .week ? .weekOfYear : (period == .month ? .month : .year)
        guard let interval = calendar.dateInterval(of: component, for: now) else {
            return ImpactStats(total: 0, completed: 0, completedOnTime: 0, overdue: 0, upcoming: 0, cancelled: 0)
        }
        let cls = CommitmentClassifier(calendar: calendar)
        // A promise belongs to the period it is due in, or was made in when undated.
        let inPeriod = list.filter { c in
            guard c.status != .draft else { return false }
            let anchor = c.dueAt ?? c.promisedAt
            return interval.contains(anchor)
        }
        var s = ImpactStats(total: inPeriod.count, completed: 0, completedOnTime: 0, overdue: 0, upcoming: 0, cancelled: 0)
        for c in inPeriod {
            switch c.status {
            case .completed:
                s.completed += 1
                if let done = c.completedAt {
                    if c.duePrecision.isHardDeadline, let local = c.dueLocal {
                        let cal = c.calendar(base: calendar)
                        let deadline = c.duePrecision == .datetime
                            ? WallClock.resolve(local, calendar: cal)?.date
                            : local.startOfDay(in: cal).flatMap { cal.date(byAdding: .day, value: 1, to: $0) }
                        if let deadline, done <= deadline { s.completedOnTime += 1 }
                    } else {
                        s.completedOnTime += 1
                    }
                }
            case .cancelled: s.cancelled += 1
            case .open, .waiting:
                if cls.isOverdue(c, now: now) { s.overdue += 1 } else { s.upcoming += 1 }
            default: break
            }
        }
        return s
    }
}
