import Foundation

/// Wall-clock time of day (e.g. 09:00) for reminders on date-only deadlines and digests.
public struct TimeOfDay: Codable, Hashable, Sendable, Comparable {
    public var hour: Int
    public var minute: Int
    public init(hour: Int, minute: Int = 0) {
        self.hour = max(0, min(23, hour))
        self.minute = max(0, min(59, minute))
    }
    public static func < (l: TimeOfDay, r: TimeOfDay) -> Bool { (l.hour, l.minute) < (r.hour, r.minute) }
}

/// What "Friday" means when said on a Friday.
public enum SameWeekdayPolicy: String, Codable, CaseIterable, Sendable {
    /// Today, if the time has not passed (shown with a visible note).
    case today
    /// The same weekday next week.
    case nextWeek
}

/// What "next Thursday" means; it varies by dialect, so the default asks.
public enum NextWeekdayPolicy: String, Codable, CaseIterable, Sendable {
    /// Always offer both candidates and require confirmation.
    case ask
    /// The nearest upcoming Thursday.
    case nearest
    /// Thursday of next calendar week.
    case followingWeek
}

public struct DateInterpretationPreferences: Codable, Hashable, Sendable {
    public var sameWeekdayPolicy: SameWeekdayPolicy
    public var nextWeekdayPolicy: NextWeekdayPolicy
    /// When set, "end of day" resolves to this time; otherwise it stays date-only.
    public var endOfDayTime: TimeOfDay?
    /// Hour used for "tonight" (always flagged as assumed).
    public var eveningTime: TimeOfDay
    /// Hour used for "morning"/"afternoon" (approximate, flagged).
    public var morningTime: TimeOfDay
    public var afternoonTime: TimeOfDay

    public init(sameWeekdayPolicy: SameWeekdayPolicy = .today,
                nextWeekdayPolicy: NextWeekdayPolicy = .ask,
                endOfDayTime: TimeOfDay? = nil,
                eveningTime: TimeOfDay = TimeOfDay(hour: 20),
                morningTime: TimeOfDay = TimeOfDay(hour: 9),
                afternoonTime: TimeOfDay = TimeOfDay(hour: 15)) {
        self.sameWeekdayPolicy = sameWeekdayPolicy
        self.nextWeekdayPolicy = nextWeekdayPolicy
        self.endOfDayTime = endOfDayTime
        self.eveningTime = eveningTime
        self.morningTime = morningTime
        self.afternoonTime = afternoonTime
    }
}

public struct ReminderSettings: Codable, Hashable, Sendable {
    public var dayBefore: Bool
    public var hourBefore: Bool
    public var atDue: Bool
    /// One gentle nudge after a missed deadline; never repeats.
    public var overdueNudge: Bool
    /// Time used for reminders on date-only deadlines.
    public var dateOnlyReminderTime: TimeOfDay
    public var waitingCheckinDays: Int
    public var approximateCheckins: Bool
    public var dailyDigestEnabled: Bool
    public var dailyDigestTime: TimeOfDay

    public init(dayBefore: Bool = true, hourBefore: Bool = false, atDue: Bool = true, overdueNudge: Bool = true,
                dateOnlyReminderTime: TimeOfDay = TimeOfDay(hour: 9), waitingCheckinDays: Int = 3,
                approximateCheckins: Bool = true, dailyDigestEnabled: Bool = false,
                dailyDigestTime: TimeOfDay = TimeOfDay(hour: 8)) {
        self.dayBefore = dayBefore
        self.hourBefore = hourBefore
        self.atDue = atDue
        self.overdueNudge = overdueNudge
        self.dateOnlyReminderTime = dateOnlyReminderTime
        self.waitingCheckinDays = max(1, waitingCheckinDays)
        self.approximateCheckins = approximateCheckins
        self.dailyDigestEnabled = dailyDigestEnabled
        self.dailyDigestTime = dailyDigestTime
    }
}

public struct AppSettings: Codable, Hashable, Sendable {
    public var reminders: ReminderSettings
    public var dates: DateInterpretationPreferences
    public var hasCompletedOnboarding: Bool
    /// Allow fully resolved Siri "Add Promise" requests to save without review.
    public var siriQuickSave: Bool
    public var spokenConfirmation: Bool

    public init(reminders: ReminderSettings = ReminderSettings(), dates: DateInterpretationPreferences = DateInterpretationPreferences(),
                hasCompletedOnboarding: Bool = false, siriQuickSave: Bool = false, spokenConfirmation: Bool = false) {
        self.reminders = reminders
        self.dates = dates
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.siriQuickSave = siriQuickSave
        self.spokenConfirmation = spokenConfirmation
    }
}
