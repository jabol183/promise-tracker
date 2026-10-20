import Foundation

/// Turns commitment state into the set of reminders that *should* exist (PRD §10).
/// Pure and deterministic; the notification center is reconciled against this output.
public struct ReminderPlanner: Sendable {
    public var settings: ReminderSettings
    public var calendar: Calendar
    public var isPro: Bool

    public static let idPrefix = "pt."

    public init(settings: ReminderSettings, calendar: Calendar = .current, isPro: Bool) {
        self.settings = settings
        self.calendar = calendar
        self.isPro = isPro
    }

    public static func reminderId(_ commitmentId: UUID, _ kind: ReminderKind, revision: Int, index: Int = 0) -> String {
        "\(idPrefix)\(commitmentId.uuidString).\(kind.rawValue).\(index).r\(revision)"
    }

    /// Commitment id embedded in a reminder identifier (used by notification actions).
    public static func commitmentId(fromReminderId id: String) -> UUID? {
        guard id.hasPrefix(idPrefix) else { return nil }
        let rest = id.dropFirst(idPrefix.count)
        guard let uuidPart = rest.split(separator: ".").first else { return nil }
        return UUID(uuidString: String(uuidPart))
    }

    public func plan(for c: Commitment, personName: String?, now: Date) -> [ReminderRule] {
        guard c.status.isActive else { return [] } // completed/cancelled/archived/draft → nothing
        let settings = ReminderPolicyOption(rawValue: c.notificationPolicyId)?.apply(to: self.settings) ?? self.settings
        let cal = c.calendar(base: calendar)
        var rules: [ReminderRule] = []
        let content = ReminderContent(commitment: c, personName: personName)

        func add(_ kind: ReminderKind, _ date: Date?, title: String, body: String, index: Int = 0) {
            guard let date, date > now else { return }
            rules.append(ReminderRule(id: Self.reminderId(c.id, kind, revision: c.revision, index: index), commitmentId: c.id,
                                      kind: kind, scheduledAt: date, revision: c.revision, title: title, body: body))
        }
        func at(_ local: LocalDateTime, _ time: TimeOfDay) -> Date? {
            WallClock.resolve(local.with(hour: time.hour, minute: time.minute), calendar: cal)?.date
        }
        let reminderTime = settings.dateOnlyReminderTime

        if c.status == .waiting && ReminderPolicyOption(rawValue: c.notificationPolicyId) != ReminderPolicyOption.none {
            // Waiting: check-ins on a cadence, never "overdue".
            let days = max(1, c.waitingCheckinDays ?? settings.waitingCheckinDays)
            let since = c.waitingSince ?? c.updatedAt
            var day = LocalDateTime(since, calendar: cal, includeTime: false).addingDays(days, calendar: cal)
            var guardCount = 0
            while let d = at(day, reminderTime), d <= now, guardCount < 400 {
                day = day.addingDays(days, calendar: cal)
                guardCount += 1
            }
            add(.waitingCheckin, at(day, reminderTime), title: "Check in", body: content.waitingBody)
        } else if c.status == .open, let local = c.dueLocal {
            switch c.duePrecision {
            case .datetime:
                let due = WallClock.resolve(local, calendar: cal)?.date
                if settings.dayBefore {
                    add(.preDue, at(local.addingDays(-1, calendar: cal), TimeOfDay(hour: local.hour ?? reminderTime.hour, minute: local.minute ?? 0)),
                        title: "Due tomorrow", body: content.dueBody(when: "tomorrow"))
                }
                if settings.hourBefore && isPro, let due {
                    add(.preDue, due.addingTimeInterval(-3600), title: "Due in an hour", body: content.dueBody(when: "in an hour"), index: 1)
                }
                if settings.atDue {
                    add(.due, due, title: "Time to follow up", body: content.dueBody(when: "now"))
                }
                if settings.overdueNudge && isPro {
                    add(.overdue, at(local.addingDays(1, calendar: cal), reminderTime), title: "Still open", body: content.overdueBody)
                }
            case .day:
                if settings.dayBefore {
                    add(.preDue, at(local.addingDays(-1, calendar: cal), reminderTime), title: "Due tomorrow", body: content.dueBody(when: "tomorrow"))
                }
                if settings.atDue {
                    add(.due, at(local, reminderTime), title: "Time to follow up", body: content.dueBody(when: "today"))
                }
                if settings.overdueNudge && isPro {
                    add(.overdue, at(local.addingDays(1, calendar: cal), reminderTime), title: "Still open", body: content.overdueBody)
                }
            case .approximate:
                // A check-in on the last day of the window — never a hard deadline.
                if settings.approximateCheckins {
                    let day = c.dueWindowEnd ?? local
                    add(.approximateCheckin, at(day, reminderTime), title: "Check in", body: content.approximateBody)
                }
            case .none, .relative, .eventLinked:
                break
            }
        }

        if isPro {
            for (i, date) in c.customReminders.sorted().enumerated() {
                add(.custom, date, title: "Reminder", body: content.dueBody(when: nil), index: i)
            }
        }

        // Snooze: suppress anything before the snooze time and add one reminder at it.
        if let snooze = c.snoozedUntil, snooze > now {
            rules.removeAll { $0.scheduledAt < snooze }
            add(.snooze, snooze, title: "Snoozed reminder", body: content.dueBody(when: nil))
        }
        return rules.sorted { $0.scheduledAt < $1.scheduledAt }
    }

    /// Daily digest for the next `days` days. Counts are deterministic queries.
    public func digest(commitments: [Commitment], now: Date, days: Int = 3) -> [ReminderRule] {
        guard settings.dailyDigestEnabled, isPro else { return [] }
        var rules: [ReminderRule] = []
        let today = LocalDateTime(now, calendar: calendar, includeTime: false)
        for offset in 0..<days {
            let day = today.addingDays(offset, calendar: calendar)
            guard let fire = WallClock.resolve(day.with(hour: settings.dailyDigestTime.hour, minute: settings.dailyDigestTime.minute), calendar: calendar)?.date,
                  fire > now else { continue }
            let summary = DigestBuilder(calendar: calendar).summary(commitments, now: fire)
            guard summary.hasAnything else { continue }
            rules.append(ReminderRule(id: "\(Self.idPrefix)digest.\(day.isoString)", commitmentId: nil, kind: .dailyDigest,
                                      scheduledAt: fire, revision: 1, title: "Your promises today", body: summary.sentence))
        }
        return rules
    }
}

/// Notification wording. Sensitive items never show their content on the lock screen.
struct ReminderContent {
    let commitment: Commitment
    let personName: String?

    private var what: String {
        let t = commitment.title.prefix(1).lowercased() + commitment.title.dropFirst()
        return t
    }

    func dueBody(when: String?) -> String {
        if commitment.isSensitive { return "You have a private promise to follow up on." }
        let suffix: String
        switch when {
        case "today": suffix = " today"
        case "tomorrow": suffix = " by tomorrow"
        default: suffix = ""
        }
        if let personName { return "You promised \(personName) to \(what)\(suffix)." }
        return "\(commitment.title)\(suffix.isEmpty ? "" : " —" + suffix)."
    }

    var overdueBody: String {
        if commitment.isSensitive { return "A private promise is past its deadline." }
        if let personName { return "“\(commitment.title)” for \(personName) is past its deadline. Done, or need a new date?" }
        return "“\(commitment.title)” is past its deadline. Done, or need a new date?"
    }

    var waitingBody: String {
        if commitment.isSensitive { return "Check whether a private promise can move forward." }
        let on = commitment.waitingOnText.map { " on \($0)" } ?? ""
        return "You’re waiting\(on) for “\(commitment.title)”. Any update?"
    }

    var approximateBody: String {
        if commitment.isSensitive { return "Check in on a private promise." }
        let phrase = commitment.agreedDueText.map { " (\($0))" } ?? ""
        let who = personName.map { " for \($0)" } ?? ""
        return "“\(commitment.title)”\(who) was planned for this period\(phrase)."
    }
}

/// Diffs desired reminders against what the OS has pending (PRD FR-05, §10).
public struct NotificationReconciler: Sendable {
    /// iOS keeps at most 64 pending local notifications per app; keep headroom.
    public static let budget = 60

    public init() {}

    public struct Plan: Equatable, Sendable {
        public var toAdd: [ReminderRule]
        public var toRemove: [String]
    }

    public func reconcile(desired: [ReminderRule], pendingIds: Set<String>, now: Date) -> Plan {
        // Prioritize near-term reminders; the rest are installed on later reconciles.
        let upcoming = desired.filter { $0.scheduledAt > now }
            .sorted { ($0.scheduledAt, $0.id) < ($1.scheduledAt, $1.id) }
            .prefix(Self.budget)
        let desiredIds = Set(upcoming.map(\.id))
        let ours = pendingIds.filter { $0.hasPrefix(ReminderPlanner.idPrefix) }
        return Plan(toAdd: upcoming.filter { !pendingIds.contains($0.id) },
                    toRemove: ours.subtracting(desiredIds).sorted())
    }
}

/// Per-promise reminder choice shown as "Remind me" on the review card.
public enum ReminderPolicyOption: String, CaseIterable, Codable, Sendable {
    /// Follow the rules in Settings.
    case `default`
    case dayBefore
    case onTheDay
    case dayBeforeAndOnTheDay
    case none

    public var label: String {
        switch self {
        case .default: return "Use my defaults"
        case .dayBefore: return "The day before"
        case .onTheDay: return "On the day"
        case .dayBeforeAndOnTheDay: return "The day before and on the day"
        case .none: return "No reminders"
        }
    }

    func apply(to s: ReminderSettings) -> ReminderSettings {
        var r = s
        switch self {
        case .default: break
        case .dayBefore: r.dayBefore = true; r.atDue = false; r.hourBefore = false
        case .onTheDay: r.dayBefore = false; r.atDue = true
        case .dayBeforeAndOnTheDay: r.dayBefore = true; r.atDue = true
        case .none:
            r.dayBefore = false; r.atDue = false; r.hourBefore = false; r.overdueNudge = false
            r.approximateCheckins = false
        }
        return r
    }
}
