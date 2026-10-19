import Foundation

/// A wall-clock date (and optional time) as the user meant it, independent of any
/// absolute instant. "Friday 16:00" stays "Friday 16:00" even if the device changes
/// time zone; the absolute `dueAt` is derived from this plus a time zone.
public struct LocalDateTime: Codable, Hashable, Sendable, Comparable {
    public var year: Int
    public var month: Int
    public var day: Int
    public var hour: Int?
    public var minute: Int?

    public init(year: Int, month: Int, day: Int, hour: Int? = nil, minute: Int? = nil) {
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
    }

    public var hasTime: Bool { hour != nil }

    public var dateOnly: LocalDateTime { LocalDateTime(year: year, month: month, day: day) }

    public func with(hour: Int, minute: Int) -> LocalDateTime {
        LocalDateTime(year: year, month: month, day: day, hour: hour, minute: minute)
    }

    public static func < (lhs: LocalDateTime, rhs: LocalDateTime) -> Bool {
        (lhs.year, lhs.month, lhs.day, lhs.hour ?? -1, lhs.minute ?? -1)
            < (rhs.year, rhs.month, rhs.day, rhs.hour ?? -1, rhs.minute ?? -1)
    }

    /// Wall-clock components of an absolute date in the given calendar's time zone.
    public init(_ date: Date, calendar: Calendar, includeTime: Bool = true) {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        self.init(year: c.year!, month: c.month!, day: c.day!,
                  hour: includeTime ? c.hour : nil, minute: includeTime ? c.minute : nil)
    }

    public var dateComponents: DateComponents {
        DateComponents(year: year, month: month, day: day, hour: hour ?? 0, minute: minute ?? 0)
    }

    /// Start of this local day in the calendar's time zone.
    public func startOfDay(in calendar: Calendar) -> Date? {
        guard let noon = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) else { return nil }
        return calendar.startOfDay(for: noon)
    }

    /// Adds whole calendar days, preserving the wall-clock time.
    public func addingDays(_ days: Int, calendar: Calendar) -> LocalDateTime {
        guard let start = startOfDay(in: calendar),
              let shifted = calendar.date(byAdding: .day, value: days, to: start) else { return self }
        var result = LocalDateTime(shifted, calendar: calendar, includeTime: false)
        result.hour = hour
        result.minute = minute
        return result
    }

    /// ISO-like stable string, used for identifiers and debugging ("2026-10-23T16:00").
    public var isoString: String {
        let d = String(format: "%04d-%02d-%02d", year, month, day)
        guard let hour else { return d }
        return d + String(format: "T%02d:%02d", hour, minute ?? 0)
    }
}

/// Result of turning a wall-clock time into an absolute instant.
public struct WallClockResolution: Equatable, Sendable {
    public enum Anomaly: String, Codable, Equatable, Sendable {
        /// The local time does not exist (spring-forward gap); shifted forward.
        case nonexistent
        /// The local time happens twice (fall-back overlap); the earlier instant is used.
        case repeated
    }

    public var date: Date
    public var anomaly: Anomaly?
}

public enum WallClock {
    /// Deterministically converts a local date-time into an absolute instant.
    /// Date-only values resolve to the start of the day.
    ///
    /// - Nonexistent times (DST gap) shift forward by the size of the gap, so 02:30 on
    ///   a spring-forward night becomes 03:30.
    /// - Repeated times (DST overlap) use the first occurrence.
    public static func resolve(_ local: LocalDateTime, calendar: Calendar) -> WallClockResolution? {
        guard let dayStart = local.startOfDay(in: calendar) else { return nil }
        guard let hour = local.hour else { return WallClockResolution(date: dayStart, anomaly: nil) }
        let minute = local.minute ?? 0
        let tz = calendar.timeZone

        // Offset in effect at the start of the day; the naive instant assumes it holds all day.
        let startOffset = tz.secondsFromGMT(for: dayStart)
        var naive = dayStart.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
        // Correct for any offset change between midnight and the target time.
        let offsetAtNaive = tz.secondsFromGMT(for: naive)
        if offsetAtNaive != startOffset {
            naive = naive.addingTimeInterval(TimeInterval(startOffset - offsetAtNaive))
        }

        let got = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: naive)
        let matches = got.year == local.year && got.month == local.month && got.day == local.day
            && got.hour == hour && got.minute == minute
        if !matches {
            // Spring-forward gap: the requested wall time is skipped. Shift forward by the gap.
            let gap = tz.secondsFromGMT(for: naive.addingTimeInterval(7200)) - startOffset
            let shifted = dayStart.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
            let candidate = gap > 0 ? shifted : naive
            return WallClockResolution(date: candidate, anomaly: .nonexistent)
        }

        // Fall-back overlap: the same wall time occurs again `delta` seconds later.
        let later = naive.addingTimeInterval(7200)
        let delta = tz.secondsFromGMT(for: naive) - tz.secondsFromGMT(for: later)
        if delta > 0 {
            let second = naive.addingTimeInterval(TimeInterval(delta))
            let c2 = calendar.dateComponents([.hour, .minute], from: second)
            if c2.hour == hour && c2.minute == minute {
                return WallClockResolution(date: naive, anomaly: .repeated)
            }
        }
        return WallClockResolution(date: naive, anomaly: nil)
    }
}
