import XCTest
@testable import PromiseCore

final class PromiseServiceTests: XCTestCase {
    var clock: FixedDateProvider!
    var storage: InMemorySnapshotStorage!
    var service: PromiseService!
    let cal = TestCalendar.make()

    override func setUpWithError() throws {
        clock = FixedDateProvider(TestCalendar.date(2026, 10, 21, 10, 0))
        storage = InMemorySnapshotStorage()
        service = PromiseService(database: try PromiseDatabase(storage: storage), clock: clock, calendar: cal)
    }

    func draft(_ title: String, person: String? = nil, due: String? = nil) -> DraftCommitment {
        CaptureInterpreter(primary: nil, resolver: makeResolver())
            .manualDraft(title: title, personName: person, duePhrase: due, capturedAt: clock.now, people: service.allPeople(), existing: service.allCommitments())
    }

    func testSaveRelaunchPersists() throws {
        let saved = try service.save(draft("Send proposal", person: "Sarah", due: "Friday at 5pm")).commitment
        let reopened = PromiseService(database: try PromiseDatabase(storage: storage), clock: clock, calendar: cal)
        let c = try XCTUnwrap(reopened.commitment(saved.id))
        XCTAssertEqual(c.title, "Send proposal")
        XCTAssertEqual(c.dueLocal, local(2026, 10, 23, 17, 0))
        XCTAssertEqual(reopened.person(c.personId!)?.displayName, "Sarah")
        XCTAssertEqual(reopened.events(for: c.id).map(\.eventType), [.created, .personLinked])
    }

    func testCreationTokenIsIdempotent() throws {
        let d = draft("Call Jamie")
        let first = try service.save(d, creationToken: "siri-123")
        let second = try service.save(d, creationToken: "siri-123")
        XCTAssertTrue(first.created)
        XCTAssertFalse(second.created)
        XCTAssertEqual(service.allCommitments().count, 1)
    }

    func testDoubleCompleteIsSafeAndLogsOnce() throws {
        let c = try service.save(draft("Call Jamie")).commitment
        try service.complete(c.id, source: .siri)
        try service.complete(c.id, source: .siri)
        XCTAssertEqual(service.commitment(c.id)?.status, .completed)
        XCTAssertEqual(service.events(for: c.id).filter { $0.eventType == .completed }.count, 1)
    }

    func testReopenAfterComplete() throws {
        let c = try service.save(draft("Call Jamie")).commitment
        try service.complete(c.id)
        try service.reopen(c.id)
        let r = try XCTUnwrap(service.commitment(c.id))
        XCTAssertEqual(r.status, .open)
        XCTAssertNil(r.completedAt)
        XCTAssertEqual(service.events(for: c.id).last?.eventType, .reopened)
    }

    func testInvalidTransitionRejected() throws {
        let c = try service.save(draft("Call Jamie")).commitment
        try service.setStatus(c.id, .archived)
        XCTAssertThrowsError(try service.setStatus(c.id, .waiting))
    }

    func testRescheduleLogsOldAndNew() throws {
        let c = try service.save(draft("Send deck", due: "tomorrow")).commitment
        try service.reschedule(c.id, to: Commitment.Due(precision: .day, local: local(2026, 10, 30), timezoneId: "Europe/London"))
        let e = try XCTUnwrap(service.events(for: c.id).last)
        XCTAssertEqual(e.eventType, .rescheduled)
        XCTAssertEqual(e.payload["from"], "day:2026-10-22@Europe/London")
        XCTAssertEqual(e.payload["to"], "day:2026-10-30@Europe/London")
    }

    func testSnoozePreservesDeadline() throws {
        let c = try service.save(draft("Send deck", due: "Friday at 5pm")).commitment
        let s = try service.snooze(c.id, minutes: 60)
        XCTAssertEqual(s.dueLocal, c.dueLocal)
        XCTAssertEqual(s.snoozedUntil, clock.now.addingTimeInterval(3600))
    }

    func testFailedWriteLeavesNoPartialState() throws {
        storage.failNextWrites = 1
        XCTAssertThrowsError(try service.save(draft("Call Jamie", person: "Jamie"))) { error in
            guard case DatabaseError.writeFailed = error else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(service.allCommitments().isEmpty)
        XCTAssertTrue(service.allPeople().isEmpty)
        XCTAssertNoThrow(try service.save(draft("Call Jamie", person: "Jamie")))
    }

    func testPartialMultiSaveReportsEachResult() throws {
        service.entitlements = EntitlementPolicy(isPro: false)
        for i in 0..<(EntitlementPolicy.freeActiveCommitmentLimit - 1) { try service.save(draft("Task \(i)")) }
        let results = service.saveAll([draft("Last free one"), draft("Over the limit")])
        XCTAssertNoThrow(try results[0].result.get())
        XCTAssertThrowsError(try results[1].result.get())
        XCTAssertEqual(service.activeCount, EntitlementPolicy.freeActiveCommitmentLimit)
    }

    func testFreeLimitNeverBlocksClosingOrEditing() throws {
        for i in 0..<EntitlementPolicy.freeActiveCommitmentLimit { try service.save(draft("Task \(i)")) }
        XCTAssertThrowsError(try service.save(draft("One more")))
        let any = try XCTUnwrap(service.allCommitments().first)
        XCTAssertNoThrow(try service.edit(any.id, .init(title: "Renamed")))
        XCTAssertNoThrow(try service.complete(any.id))
        XCTAssertNoThrow(try service.save(draft("Now there is room")))
    }

    func testProRemovesLimits() throws {
        service.entitlements = EntitlementPolicy(isPro: true)
        for i in 0..<(EntitlementPolicy.freeActiveCommitmentLimit + 5) { try service.save(draft("Task \(i)")) }
        XCTAssertEqual(service.activeCount, EntitlementPolicy.freeActiveCommitmentLimit + 5)
    }

    func testWaitingIsOnlyFromExplicitSave() throws {
        var d = draft("Send contract", person: "Tom")
        d.waitingOn = "Legal approval"
        d.startAsWaiting = true
        let c = try service.save(d).commitment
        XCTAssertEqual(c.status, .waiting)
        XCTAssertEqual(c.waitingOnText, "Legal approval")
    }

    func testDeletingPersonKeepsHistoryReadable() throws {
        let c = try service.save(draft("Send deck", person: "Anna")).commitment
        try service.deletePerson(c.personId!)
        let after = try XCTUnwrap(service.commitment(c.id))
        XCTAssertNil(after.personId)
        XCTAssertEqual(after.context, "For Anna")
    }

    func testMergeIsExplicitAndKeepsAlias() throws {
        let a = try service.createPerson(named: "Katie")
        let b = try service.createPerson(named: "Kate Lee")
        var d = draft("Send deck"); d.choosePerson(a.id)
        let c = try service.save(d).commitment
        try service.mergePeople(source: a.id, into: b.id)
        XCTAssertEqual(service.commitment(c.id)?.personId, b.id)
        XCTAssertTrue(service.person(b.id)!.aliases.contains("Katie"))
        XCTAssertEqual(service.person(a.id)?.mergedIntoId, b.id)
        XCTAssertEqual(PersonMatcher().match(name: "Katie", in: service.allPeople()), .matched(b.id))
    }

    func testDeleteRemovesContentAndIsIdempotent() throws {
        let c = try service.save(draft("Secret thing", person: "Bo")).commitment
        try service.delete(c.id)
        try service.delete(c.id)
        XCTAssertNil(service.commitment(c.id))
        let events = service.events(for: c.id)
        XCTAssertEqual(events.map(\.eventType), [.deleted])
        XCTAssertTrue(events[0].payload.isEmpty)
    }

    func testExportImportRoundTrip() throws {
        try service.save(draft("Send deck", person: "Anna", due: "tomorrow"))
        let data = try service.database.exportJSON()
        let other = PromiseService(database: try PromiseDatabase(storage: InMemorySnapshotStorage()), clock: clock, calendar: cal)
        try other.database.importJSON(data)
        XCTAssertEqual(other.allCommitments().map(\.title), ["Send deck"])
        XCTAssertEqual(other.allPeople().map(\.displayName), ["Anna"])
    }

    func testAIFollowUpCountOnlyCountsAIRewritesInWindow() throws {
        let c = try service.save(draft("Send deck")).commitment
        service.recordFollowUpDrafted(c.id)
        service.recordFollowUpDrafted(c.id, usedAI: true)
        clock.advance(by: 8 * 86400)
        service.recordFollowUpDrafted(c.id, usedAI: true)
        XCTAssertEqual(service.aiFollowUpCount(since: clock.now.addingTimeInterval(-7 * 86400)), 1)
        XCTAssertEqual(service.aiFollowUpCount(since: .distantPast), 2)
    }

    func testEraseAll() throws {
        try service.save(draft("Send deck", person: "Anna"))
        try service.eraseAllData()
        XCTAssertTrue(service.allCommitments().isEmpty)
        let reopened = try PromiseDatabase(storage: storage)
        XCTAssertTrue(reopened.read { $0.commitments.isEmpty })
    }
}

final class PersistenceTests: XCTestCase {
    func testNewerSchemaIsNotOverwritten() throws {
        let data = #"{"schemaVersion": 99, "commitments": []}"#.data(using: .utf8)!
        let storage = InMemorySnapshotStorage(data: data)
        XCTAssertThrowsError(try PromiseDatabase(storage: storage)) { error in
            XCTAssertEqual(error as? DatabaseError, .newerSchema(found: 99))
        }
        XCTAssertEqual(try storage.load(), data)
    }

    func testCorruptFileIsMovedAsideNotLost() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("promises.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let db = try PromiseDatabase(storage: FileSnapshotStorage(url: url))
        guard case let .corrupted(path)? = db.recoveryNotice else { return XCTFail("expected recovery notice") }
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "not json")
        try? FileManager.default.removeItem(at: dir)
    }

    func testMigratesUnversionedFile() throws {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        var object = try JSONSerialization.jsonObject(with: enc.encode(DatabaseSnapshot())) as! [String: Any]
        object.removeValue(forKey: "schemaVersion")
        object.removeValue(forKey: "creationTokens")
        let storage = InMemorySnapshotStorage(data: try JSONSerialization.data(withJSONObject: object))
        let db = try PromiseDatabase(storage: storage)
        XCTAssertEqual(db.read { $0.schemaVersion }, DatabaseSnapshot.currentSchemaVersion)
    }

    func testFileStorageRoundTripAndExternalChangeDetection() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("p.json")
        let clock = FixedDateProvider(Date(timeIntervalSince1970: 1_800_000_000))
        let a = PromiseService(database: try PromiseDatabase(storage: FileSnapshotStorage(url: url)), clock: clock)
        let b = PromiseService(database: try PromiseDatabase(storage: FileSnapshotStorage(url: url)), clock: clock)
        let d = DraftCommitment(rawText: "x", sourceType: .siri, capturedAt: clock.now, title: "From another process")
        Thread.sleep(forTimeInterval: 0.01)
        try b.save(d)
        XCTAssertEqual(a.allCommitments().map(\.title), ["From another process"])
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

final class ReminderPlannerTests: XCTestCase {
    let cal = TestCalendar.make()
    let now = TestCalendar.date(2026, 10, 21, 10, 0)

    func commitment(_ due: Commitment.Due?, status: CommitmentStatus = .open) -> Commitment {
        var c = Commitment(title: "Send proposal", status: status, createdAt: now, timezoneId: "Europe/London")
        if let due { c.apply(due: due, baseCalendar: cal) }
        return c
    }

    func testExactTimeGetsDayBeforeAndAtDue() {
        let c = commitment(Commitment.Due(precision: .datetime, local: local(2026, 10, 23, 16, 0), timezoneId: "Europe/London"))
        let rules = ReminderPlanner(settings: ReminderSettings(), calendar: cal, isPro: false).plan(for: c, personName: "Sarah", now: now)
        XCTAssertEqual(rules.map(\.kind), [.preDue, .due])
        XCTAssertEqual(rules[1].scheduledAt, TestCalendar.date(2026, 10, 23, 16, 0))
        XCTAssertEqual(rules[1].body, "You promised Sarah to send proposal.")
    }

    func testDateOnlyUsesPreferredTimeNotMidnight() {
        let c = commitment(Commitment.Due(precision: .day, local: local(2026, 10, 23), timezoneId: "Europe/London"))
        let settings = ReminderSettings(dayBefore: false, dateOnlyReminderTime: TimeOfDay(hour: 9, minute: 30))
        let rules = ReminderPlanner(settings: settings, calendar: cal, isPro: false).plan(for: c, personName: nil, now: now)
        XCTAssertEqual(rules.map(\.scheduledAt), [TestCalendar.date(2026, 10, 23, 9, 30)])
    }

    func testApproximateGetsCheckInNotDeadline() {
        let c = commitment(Commitment.Due(precision: .approximate, local: local(2026, 10, 26), windowEnd: local(2026, 11, 1), timezoneId: "Europe/London", phrase: "next week"))
        let rules = ReminderPlanner(settings: ReminderSettings(), calendar: cal, isPro: true).plan(for: c, personName: nil, now: now)
        XCTAssertEqual(rules.map(\.kind), [.approximateCheckin])
        XCTAssertEqual(rules[0].scheduledAt, TestCalendar.date(2026, 11, 1, 9, 0))
    }

    func testUnscheduledAndClosedGetNothing() {
        let planner = ReminderPlanner(settings: ReminderSettings(), calendar: cal, isPro: true)
        XCTAssertTrue(planner.plan(for: commitment(nil), personName: nil, now: now).isEmpty)
        let due = Commitment.Due(precision: .day, local: local(2026, 10, 23), timezoneId: "Europe/London")
        XCTAssertTrue(planner.plan(for: commitment(due, status: .completed), personName: nil, now: now).isEmpty)
        XCTAssertTrue(planner.plan(for: commitment(due, status: .cancelled), personName: nil, now: now).isEmpty)
    }

    func testWaitingUsesCadenceAndNeverOverdue() {
        var c = commitment(Commitment.Due(precision: .day, local: local(2026, 10, 1), timezoneId: "Europe/London"), status: .waiting)
        c.waitingSince = TestCalendar.date(2026, 10, 15, 12, 0)
        c.waitingCheckinDays = 3
        let rules = ReminderPlanner(settings: ReminderSettings(), calendar: cal, isPro: true).plan(for: c, personName: nil, now: now)
        XCTAssertEqual(rules.map(\.kind), [.waitingCheckin])
        XCTAssertEqual(rules[0].scheduledAt, TestCalendar.date(2026, 10, 21, 9, 0).addingTimeInterval(3 * 86400))
        XCTAssertFalse(CommitmentClassifier(calendar: cal).isOverdue(c, now: now))
    }

    func testSnoozeSuppressesEarlierRemindersOnly() {
        var c = commitment(Commitment.Due(precision: .datetime, local: local(2026, 10, 23, 16, 0), timezoneId: "Europe/London"))
        c.snoozedUntil = TestCalendar.date(2026, 10, 23, 12, 0)
        let rules = ReminderPlanner(settings: ReminderSettings(), calendar: cal, isPro: false).plan(for: c, personName: nil, now: now)
        XCTAssertEqual(rules.map(\.kind), [.snooze, .due])
    }

    func testAdvancedRulesNeedPro() {
        let c = commitment(Commitment.Due(precision: .datetime, local: local(2026, 10, 23, 16, 0), timezoneId: "Europe/London"))
        let settings = ReminderSettings(hourBefore: true, overdueNudge: true)
        XCTAssertEqual(ReminderPlanner(settings: settings, calendar: cal, isPro: false).plan(for: c, personName: nil, now: now).count, 2)
        XCTAssertEqual(ReminderPlanner(settings: settings, calendar: cal, isPro: true).plan(for: c, personName: nil, now: now).count, 4)
    }

    func testIdsChangeWithRevisionSoEditsReplaceReminders() {
        var c = commitment(Commitment.Due(precision: .day, local: local(2026, 10, 23), timezoneId: "Europe/London"))
        let planner = ReminderPlanner(settings: ReminderSettings(), calendar: cal, isPro: false)
        let before = Set(planner.plan(for: c, personName: nil, now: now).map(\.id))
        c.revision += 1
        let after = Set(planner.plan(for: c, personName: nil, now: now).map(\.id))
        XCTAssertTrue(before.isDisjoint(with: after))
        XCTAssertEqual(ReminderPlanner.commitmentId(fromReminderId: after.first!), c.id)
    }

    func testSensitiveItemsHideContent() {
        var c = commitment(Commitment.Due(precision: .day, local: local(2026, 10, 23), timezoneId: "Europe/London"))
        c.isSensitive = true
        let rules = ReminderPlanner(settings: ReminderSettings(), calendar: cal, isPro: false).plan(for: c, personName: "Dr Lee", now: now)
        XCTAssertTrue(rules.allSatisfy { !$0.body.contains("Dr Lee") && !$0.body.contains("proposal") })
    }

    func testReconcilerDiffsAndRespectsBudget() {
        let planner = ReminderPlanner(settings: ReminderSettings(), calendar: cal, isPro: false)
        var desired: [ReminderRule] = []
        for i in 0..<50 {
            let c = commitment(Commitment.Due(precision: .datetime, local: local(2026, 10, 22, 9, 0).addingDays(i, calendar: cal), timezoneId: "Europe/London"))
            desired += planner.plan(for: c, personName: nil, now: now)
        }
        let stale = "pt.\(UUID().uuidString).due.0.r1"
        let plan = NotificationReconciler().reconcile(desired: desired, pendingIds: [desired[0].id, stale, "someone-else"], now: now)
        XCTAssertEqual(plan.toRemove, [stale])
        XCTAssertEqual(plan.toAdd.count, NotificationReconciler.budget - 1)
        XCTAssertFalse(plan.toAdd.contains { $0.id == desired[0].id })
        // Nearest first.
        XCTAssertEqual(plan.toAdd.map(\.scheduledAt), plan.toAdd.map(\.scheduledAt).sorted())
    }

    func testDigestCountsAndDedupedPerDay() {
        let planner = ReminderPlanner(settings: ReminderSettings(dailyDigestEnabled: true), calendar: cal, isPro: true)
        let today = commitment(Commitment.Due(precision: .day, local: local(2026, 10, 22), timezoneId: "Europe/London"))
        let rules = planner.digest(commitments: [today], now: now, days: 3)
        XCTAssertEqual(Set(rules.map(\.id)).count, rules.count)
        XCTAssertEqual(rules.first?.body, "You have 1 promise due today.")
    }
}

final class ClassifierAndSearchTests: XCTestCase {
    let cal = TestCalendar.make()
    let now = TestCalendar.date(2026, 10, 21, 10, 0)

    func c(_ title: String, _ due: Commitment.Due?, status: CommitmentStatus = .open) -> Commitment {
        var x = Commitment(title: title, status: status, createdAt: now, timezoneId: "Europe/London")
        if let due { x.apply(due: due, baseCalendar: cal) }
        return x
    }

    func testBucketsAndOverdueReason() {
        let cls = CommitmentClassifier(calendar: cal)
        let overdue = c("A", Commitment.Due(precision: .day, local: local(2026, 10, 19), timezoneId: "Europe/London", phrase: "by Monday"))
        let todayLate = c("B", Commitment.Due(precision: .datetime, local: local(2026, 10, 21, 9, 0), timezoneId: "Europe/London"))
        let todayDateOnly = c("C", Commitment.Due(precision: .day, local: local(2026, 10, 21), timezoneId: "Europe/London"))
        let approxPast = c("D", Commitment.Due(precision: .approximate, local: local(2026, 10, 12), windowEnd: local(2026, 10, 18), timezoneId: "Europe/London"))
        XCTAssertEqual(cls.bucket(overdue, now: now), .overdue)
        XCTAssertEqual(cls.bucket(todayLate, now: now), .overdue)
        XCTAssertEqual(cls.bucket(todayDateOnly, now: now), .dueToday, "date-only is not overdue until the day ends")
        XCTAssertEqual(cls.bucket(approxPast, now: now), .approximate, "approximate periods are never overdue")
        let reason = cls.overdueReason(overdue, now: now, locale: Locale(identifier: "en_GB"))
        XCTAssertTrue(reason?.contains("2 days ago") ?? false, reason ?? "nil")
        XCTAssertTrue(reason?.contains("by Monday") ?? false)
    }

    func testDigestSentence() {
        let s = DigestSummary(dueToday: 2, overdue: 1, waiting: 2, dueThisWeek: 3, unscheduled: 0)
        XCTAssertEqual(s.sentence, "You have 2 promises due today, 1 overdue and 2 waiting for responses.")
        XCTAssertEqual(s.headline, "2 due today · 1 overdue · 2 waiting")
    }

    func testSearchIsDiacriticAndPrefixTolerant() {
        let zofia = Person(displayName: "Zofia Łukasik", createdAt: now)
        var item = c("Send the revised proposal", nil)
        item.personId = zofia.id
        let other = c("Book dentist", nil)
        let s = SearchService()
        XCTAssertEqual(s.search(SearchQuery(text: "lukasik prop"), commitments: [item, other], people: [zofia]).map(\.title), ["Send the revised proposal"])
        XCTAssertEqual(s.search(SearchQuery(text: "", statuses: [.completed]), commitments: [item, other], people: []).count, 0)
    }

    func testStatsCountWithoutScoring() {
        var done = c("Done", Commitment.Due(precision: .day, local: local(2026, 10, 20), timezoneId: "Europe/London"), status: .completed)
        done.completedAt = TestCalendar.date(2026, 10, 20, 12, 0)
        let late = c("Late", Commitment.Due(precision: .day, local: local(2026, 10, 2), timezoneId: "Europe/London"))
        let cancelled = c("Cancelled", Commitment.Due(precision: .day, local: local(2026, 10, 5), timezoneId: "Europe/London"), status: .cancelled)
        let stats = ImpactStats.compute([done, late, cancelled], period: .month, now: now, calendar: cal)
        XCTAssertEqual(stats.total, 3)
        XCTAssertEqual(stats.completed, 1)
        XCTAssertEqual(stats.completedOnTime, 1)
        XCTAssertEqual(stats.overdue, 1)
        XCTAssertEqual(stats.keptRate, 0.5)
    }

    func testCSVEscapesFormulas() {
        let x = c("=HYPERLINK(\"evil\")", nil)
        let csv = CSVExporter().export(commitments: [x], people: [])
        XCTAssertTrue(csv.contains("\"'=HYPERLINK(\"\"evil\"\")\""))
    }

    func testFollowUpTemplateNeverClaimsSent() {
        let item = c("Send the revised proposal", nil, status: .completed)
        let text = FollowUpTemplates().draft(for: item, recipient: "Sarah Chen", sender: "Alex", kind: .delivered, tone: .friendly)
        XCTAssertTrue(text.hasPrefix("Hi Sarah,"))
        XCTAssertTrue(text.contains("I’ve sent the revised proposal"))
        XCTAssertTrue(text.hasSuffix("Best regards,\nAlex"))
    }
}
