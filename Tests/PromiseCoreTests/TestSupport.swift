import Foundation
@testable import PromiseCore

enum TestCalendar {
    static func make(_ tz: String = "Europe/London", locale: String = "en_GB", firstWeekday: Int = 2) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: tz)!
        cal.locale = Locale(identifier: locale)
        cal.firstWeekday = firstWeekday
        return cal
    }

    static func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, tz: String = "Europe/London") -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: tz)!
        return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }
}

func makeResolver(tz: String = "Europe/London", locale: String = "en_GB", firstWeekday: Int = 2,
                  prefs: DateInterpretationPreferences = DateInterpretationPreferences()) -> DateResolver {
    DateResolver(calendar: TestCalendar.make(tz, locale: locale, firstWeekday: firstWeekday),
                 locale: Locale(identifier: locale), preferences: prefs)
}

func local(_ y: Int, _ m: Int, _ d: Int, _ h: Int? = nil, _ mi: Int? = nil) -> LocalDateTime {
    LocalDateTime(year: y, month: m, day: d, hour: h, minute: h == nil ? nil : (mi ?? 0))
}
