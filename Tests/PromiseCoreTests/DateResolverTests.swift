import XCTest
@testable import PromiseCore

/// Anchor: Wednesday 21 October 2026, 10:00 London (BST). Weeks start Monday.
final class DateResolverTests: XCTestCase {
    let anchor = TestCalendar.date(2026, 10, 21, 10, 0)
    let resolver = makeResolver()

    func testTomorrowIsNextCalendarDay() {
        let r = resolver.resolve("tomorrow", anchor: anchor)
        XCTAssertEqual(r.proposed?.due.local, local(2026, 10, 22))
        XCTAssertEqual(r.proposed?.due.precision, .day)
        XCTAssertFalse(r.needsConfirmation)
    }

    func testTomorrowNearMidnightUsesLocalDay() {
        // 23:30 London is 22:30 UTC — "tomorrow" must follow the local calendar.
        let late = TestCalendar.date(2026, 10, 21, 23, 30)
        XCTAssertEqual(resolver.resolve("tomorrow", anchor: late).proposed?.due.local, local(2026, 10, 22))
    }

    func testFridayAtFourIsAmbiguousMeridiem() {
        let r = resolver.resolve("by Friday at four", anchor: anchor)
        XCTAssertEqual(r.proposed?.due.local, local(2026, 10, 23, 16, 0))
        XCTAssertEqual(r.proposed?.due.precision, .datetime)
        XCTAssertEqual(r.candidates.dropFirst().first?.due.local, local(2026, 10, 23, 4, 0))
        XCTAssertTrue(r.ambiguities.contains { $0.kind == .meridiem })
        XCTAssertTrue(r.needsConfirmation)
    }

    func testExplicitMeridiemNeedsNoConfirmation() {
        let r = resolver.resolve("Friday at 4pm", anchor: anchor)
        XCTAssertEqual(r.proposed?.due.local, local(2026, 10, 23, 16, 0))
        XCTAssertFalse(r.needsConfirmation)
        XCTAssertEqual(resolver.resolve("Friday 16:30", anchor: anchor).proposed?.due.local, local(2026, 10, 23, 16, 30))
        XCTAssertEqual(resolver.resolve("Friday at 9 in the morning", anchor: anchor).proposed?.due.local, local(2026, 10, 23, 9, 0))
    }

    func testSameWeekdayDefaultsToTodayWithVisibleNote() {
        let friday = TestCalendar.date(2026, 10, 23, 9, 0)
        let r = resolver.resolve("Friday", anchor: friday)
        XCTAssertEqual(r.proposed?.due.local, local(2026, 10, 23))
        XCTAssertEqual(r.candidates[1].due.local, local(2026, 10, 30))
        XCTAssertTrue(r.ambiguities.contains { $0.kind == .sameWeekday })
        XCTAssertFalse(r.needsConfirmation)

        let nextWeekPolicy = makeResolver(prefs: DateInterpretationPreferences(sameWeekdayPolicy: .nextWeek))
        XCTAssertEqual(nextWeekPolicy.resolve("Friday", anchor: friday).proposed?.due.local, local(2026, 10, 30))
    }

    func testNextWeekdayAsksWhenDatesDiffer() {
        let r = resolver.resolve("next Thursday", anchor: anchor)
        XCTAssertEqual(Set(r.candidates.compactMap(\.due.local)), [local(2026, 10, 22), local(2026, 10, 29)])
        XCTAssertTrue(r.needsConfirmation)

        let nearest = makeResolver(prefs: DateInterpretationPreferences(nextWeekdayPolicy: .nearest))
        let n = nearest.resolve("next Thursday", anchor: anchor)
        XCTAssertEqual(n.proposed?.due.local, local(2026, 10, 22))
        XCTAssertFalse(n.needsConfirmation)
    }

    func testNextWeekdayUnambiguousWhenBothReadingsAgree() {
        let saturday = TestCalendar.date(2026, 10, 24, 10, 0)
        let r = resolver.resolve("next Monday", anchor: saturday)
        XCTAssertEqual(r.candidates.map(\.due.local), [local(2026, 10, 26)])
        XCTAssertFalse(r.needsConfirmation)
    }

    func testThisWeekIsARangeNotFriday() {
        let r = resolver.resolve("this week", anchor: anchor)
        XCTAssertEqual(r.proposed?.due.precision, .approximate)
        XCTAssertEqual(r.proposed?.due.local, local(2026, 10, 21))
        XCTAssertEqual(r.proposed?.due.windowEnd, local(2026, 10, 25))
        XCTAssertFalse(r.needsConfirmation)
    }

    func testNextWeekRangeRespectsRegionalWeekStart() {
        let r = resolver.resolve("sometime next week", anchor: anchor)
        XCTAssertEqual(r.proposed?.due.local, local(2026, 10, 26))
        XCTAssertEqual(r.proposed?.due.windowEnd, local(2026, 11, 1))

        let us = makeResolver(tz: "America/New_York", locale: "en_US", firstWeekday: 1)
        let usAnchor = TestCalendar.date(2026, 10, 21, 10, 0, tz: "America/New_York")
        let u = us.resolve("next week", anchor: usAnchor)
        XCTAssertEqual(u.proposed?.due.local, local(2026, 10, 25))
        XCTAssertEqual(u.proposed?.due.windowEnd, local(2026, 10, 31))
    }

    func testEndOfDayUsesPreferenceOrStaysDateOnly() {
        let r = resolver.resolve("by end of day", anchor: anchor)
        XCTAssertEqual(r.proposed?.due.precision, .day)
        XCTAssertTrue(r.ambiguities.contains { $0.kind == .endOfDayUnspecified })

        let withPref = makeResolver(prefs: DateInterpretationPreferences(endOfDayTime: TimeOfDay(hour: 17, minute: 30)))
        let p = withPref.resolve("EOD tomorrow", anchor: anchor)
        XCTAssertEqual(p.proposed?.due.local, local(2026, 10, 22, 17, 30))
    }

    func testEventLinkedAndVaguePhrasesAreNotDated() {
        let event = resolver.resolve("after the meeting", anchor: anchor)
        XCTAssertEqual(event.proposed?.due.precision, .eventLinked)
        XCTAssertNil(event.proposed?.due.local)

        let vague = resolver.resolve("sometime", anchor: anchor)
        XCTAssertEqual(vague.proposed?.due.precision, .approximate)
        XCTAssertNil(vague.proposed?.due.local)

        let nonsense = resolver.resolve("whenever the stars align", anchor: anchor)
        XCTAssertTrue(nonsense.candidates.isEmpty)
        XCTAssertTrue(nonsense.ambiguities.contains { $0.kind == .unrecognized })
    }

    func testRelativeOffsets() {
        XCTAssertEqual(resolver.resolve("in 2 hours", anchor: anchor).proposed?.due.local, local(2026, 10, 21, 12, 0))
        XCTAssertEqual(resolver.resolve("in three days", anchor: anchor).proposed?.due.local, local(2026, 10, 24))
        XCTAssertEqual(resolver.resolve("in a week", anchor: anchor).proposed?.due.local, local(2026, 10, 28))
        XCTAssertEqual(resolver.resolve("in a fortnight", anchor: anchor).proposed?.due.local, local(2026, 11, 4))
        XCTAssertEqual(resolver.resolve("in a few days", anchor: anchor).proposed?.due.precision, .approximate)
    }

    func testExplicitDatesAndYearRollover() {
        XCTAssertEqual(resolver.resolve("October 24th", anchor: anchor).proposed?.due.local, local(2026, 10, 24))
        XCTAssertEqual(resolver.resolve("24 October at 3:15pm", anchor: anchor).proposed?.due.local, local(2026, 10, 24, 15, 15))
        XCTAssertEqual(resolver.resolve("March 3", anchor: anchor).proposed?.due.local, local(2027, 3, 3))
        XCTAssertEqual(resolver.resolve("2026-12-01", anchor: anchor).proposed?.due.local, local(2026, 12, 1))
        XCTAssertEqual(resolver.resolve("the 30th", anchor: anchor).proposed?.due.local, local(2026, 10, 30))
        XCTAssertEqual(resolver.resolve("the 2nd", anchor: anchor).proposed?.due.local, local(2026, 11, 2))
    }

    func testLeapYear() {
        XCTAssertEqual(resolver.resolve("February 29 2028", anchor: anchor).proposed?.due.local, local(2028, 2, 29))
        let invalid = resolver.resolve("February 29 2027", anchor: anchor)
        XCTAssertTrue(invalid.candidates.isEmpty)
        XCTAssertTrue(invalid.ambiguities.contains { $0.kind == .invalidDate })
    }

    func testRecentPastDateIsFlaggedNotMoved() {
        let r = resolver.resolve("October 18", anchor: anchor)
        XCTAssertEqual(r.proposed?.due.local, local(2026, 10, 18))
        XCTAssertTrue(r.ambiguities.contains { $0.kind == .pastDate })
        XCTAssertTrue(r.needsConfirmation)

        let earlier = resolver.resolve("today at 9am", anchor: anchor)
        XCTAssertTrue(earlier.ambiguities.contains { $0.kind == .pastDate })
    }

    func testNumericDateOrderDependsOnLocale() {
        let gb = resolver.resolve("05/06", anchor: anchor)
        XCTAssertEqual(gb.proposed?.due.local, local(2027, 6, 5))
        XCTAssertTrue(gb.ambiguities.contains { $0.kind == .numericDateOrder })

        let us = makeResolver(tz: "America/New_York", locale: "en_US", firstWeekday: 1)
        XCTAssertEqual(us.resolve("05/06", anchor: anchor).proposed?.due.local, local(2027, 5, 6))

        let unambiguous = resolver.resolve("25/12", anchor: anchor)
        XCTAssertEqual(unambiguous.proposed?.due.local, local(2026, 12, 25))
        XCTAssertFalse(unambiguous.needsConfirmation)
    }

    func testTimeWithoutDayRollsToTomorrowWhenPassed() {
        let r = resolver.resolve("at 9am", anchor: anchor)
        XCTAssertEqual(r.proposed?.due.local, local(2026, 10, 22, 9, 0))
        XCTAssertTrue(r.ambiguities.contains { $0.kind == .assumedDay })
        let later = resolver.resolve("at 3pm", anchor: anchor)
        XCTAssertEqual(later.proposed?.due.local, local(2026, 10, 21, 15, 0))
    }

    func testTonightAssumesEveningTime() {
        let r = resolver.resolve("tonight", anchor: anchor)
        XCTAssertEqual(r.proposed?.due.local, local(2026, 10, 21, 20, 0))
        XCTAssertTrue(r.ambiguities.contains { $0.kind == .assumedTime })
        XCTAssertEqual(resolver.resolve("tonight at 9", anchor: anchor).proposed?.due.local, local(2026, 10, 21, 21, 0))
    }

    func testRepeatedLocalTimeAtFallBack() {
        // UK clocks go back at 02:00 BST on Sunday 25 October 2026.
        let r = resolver.resolve("Sunday at 1:30am", anchor: anchor)
        XCTAssertEqual(r.proposed?.due.local, local(2026, 10, 25, 1, 30))
        XCTAssertTrue(r.ambiguities.contains { $0.kind == .repeatedLocalTime })
        // First occurrence: 00:30 UTC.
        XCTAssertEqual(r.proposed?.resolvedAt, Date(timeIntervalSince1970: 1_792_888_200))
    }

    func testNonexistentLocalTimeAtSpringForward() {
        // US clocks jump from 02:00 to 03:00 on Sunday 8 March 2026.
        let ny = makeResolver(tz: "America/New_York", locale: "en_US", firstWeekday: 1)
        let fri = TestCalendar.date(2026, 3, 6, 10, 0, tz: "America/New_York")
        let r = ny.resolve("Sunday at 2:30am", anchor: fri)
        XCTAssertTrue(r.ambiguities.contains { $0.kind == .nonexistentLocalTime })
        XCTAssertEqual(r.proposed?.resolvedAt, TestCalendar.date(2026, 3, 8, 3, 30, tz: "America/New_York"))
    }

    func testDSTDoesNotShiftNormalTimes() {
        // 16:00 on the fall-back day must still be 16:00 local.
        let r = resolver.resolve("Sunday at 4pm", anchor: anchor)
        XCTAssertEqual(r.proposed?.resolvedAt, TestCalendar.date(2026, 10, 25, 16, 0))
    }

    func testPolishLexicon() {
        let pl = DateResolver(calendar: TestCalendar.make("Europe/Warsaw", locale: "pl_PL"), locale: Locale(identifier: "pl_PL"))
        let a = TestCalendar.date(2026, 10, 21, 10, 0, tz: "Europe/Warsaw")
        XCTAssertEqual(pl.resolve("jutro o 16", anchor: a).proposed?.due.local, local(2026, 10, 22, 16, 0))
        XCTAssertEqual(pl.resolve("do piątku", anchor: a).proposed?.due.local, local(2026, 10, 23))
        XCTAssertEqual(pl.resolve("w przyszłym tygodniu", anchor: a).proposed?.due.precision, .approximate)
    }
}

final class DatePhraseScannerTests: XCTestCase {
    let scanner = DatePhraseScanner()

    func testFindsVerbatimPhraseWithPreposition() {
        let text = "I promised Sarah I'd send her the revised proposal by Thursday, but I need Mike's figures first."
        XCTAssertEqual(scanner.scan(text).map(\.phrase), ["by Thursday"])
    }

    func testMergesDayAndTime() {
        let text = "I promised Anna I’d send the finished website by Friday at four."
        XCTAssertEqual(scanner.scan(text).map(\.phrase), ["by Friday at four"])
    }

    func testIgnoresCommonWordsThatLookLikeDates() {
        XCTAssertTrue(scanner.scan("I sat down with Anna and we may meet the sun team").isEmpty)
        XCTAssertTrue(scanner.scan("I'll send one copy to Mark").isEmpty)
    }

    func testKeepsDiacriticsInVerbatimPhrase() {
        let pl = DatePhraseScanner(lexicon: .polish)
        XCTAssertEqual(pl.scan("Obiecałem Zosi, że wyślę raport do piątku.").map(\.phrase), ["do piątku"])
    }
}

final class WallClockTests: XCTestCase {
    func testDateOnlyResolvesToStartOfDay() {
        let cal = TestCalendar.make()
        let r = WallClock.resolve(local(2026, 10, 25), calendar: cal)
        XCTAssertEqual(r?.date, TestCalendar.date(2026, 10, 25, 0, 0))
        XCTAssertNil(r?.anomaly)
    }

    func testLocalDateTimeAddingDaysAcrossDST() {
        let cal = TestCalendar.make()
        let d = local(2026, 10, 24, 9, 0).addingDays(1, calendar: cal)
        XCTAssertEqual(d, local(2026, 10, 25, 9, 0))
    }
}
