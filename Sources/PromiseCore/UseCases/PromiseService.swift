import Foundation

/// All mutations go through here: each one is a single database transaction that also
/// appends history. UI, App Intents and notification actions share this one service.
public final class PromiseService: @unchecked Sendable {
    public let database: PromiseDatabase
    public let clock: DateProvider
    public var calendar: Calendar
    /// Called after every successful mutation (e.g. to reconcile notifications).
    public var onChange: (@Sendable () -> Void)?
    public var entitlements: EntitlementPolicy

    public init(database: PromiseDatabase, clock: DateProvider = SystemDateProvider(), calendar: Calendar = .current,
                entitlements: EntitlementPolicy = EntitlementPolicy(isPro: false)) {
        self.database = database
        self.clock = clock
        self.calendar = calendar
        self.entitlements = entitlements
    }

    // MARK: Queries

    public var settings: AppSettings { database.read { $0.settings } }
    public func commitment(_ id: UUID) -> Commitment? { database.read { $0.commitments[id] } }
    public func person(_ id: UUID) -> Person? { database.read { $0.people[id] } }
    public func allCommitments() -> [Commitment] { database.read { Array($0.commitments.values) } }
    public func allPeople() -> [Person] { database.read { Array($0.people.values) } }
    public var activePeople: [Person] { allPeople().filter { !$0.isArchived && $0.mergedIntoId == nil } }

    public func events(for id: UUID) -> [ActivityEvent] {
        database.read { $0.events.filter { $0.commitmentId == id }.sorted { $0.occurredAt < $1.occurredAt } }
    }

    public func commitments(for personId: UUID) -> [Commitment] {
        allCommitments().filter { $0.personId == personId || $0.waitingOnPersonId == personId }
    }

    public var activeCount: Int { allCommitments().filter { $0.status.isActive }.count }

    // MARK: Create

    public struct SaveOutcome: Equatable, Sendable {
        public var commitment: Commitment
        /// False when an idempotency token matched an earlier save.
        public var created: Bool
    }

    /// Saves a reviewed draft. Pass a `creationToken` for retried Siri/Shortcut calls so
    /// they never create duplicates (edge case 15).
    @discardableResult
    public func save(_ draft: DraftCommitment, creationToken: String? = nil) throws -> SaveOutcome {
        guard draft.canSave else { throw DatabaseError.validation(draft.blockingIssues.joined(separator: " ")) }
        let now = clock.now
        let outcome: SaveOutcome = try database.write { db in
            if let token = creationToken, let existingId = db.creationTokens[token], let existing = db.commitments[existingId] {
                return SaveOutcome(commitment: existing, created: false)
            }
            let active = db.commitments.values.filter { $0.status.isActive }.count
            guard entitlements.canCreateCommitment(activeCount: active) else {
                throw DatabaseError.limitReached(entitlements.commitmentLimitMessage)
            }

            var personId: UUID?
            switch draft.personMatch {
            case let .matched(id), let .suggested(id):
                personId = db.people[id] != nil ? id : nil
            case let .new(name):
                personId = try Self.findOrCreatePerson(named: name, in: &db, now: now, entitlements: entitlements)
            case .none, .ambiguous:
                personId = nil
            }

            var c = Commitment(title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
                               originalInput: draft.sourceSpan ?? draft.rawText,
                               status: draft.startAsWaiting ? .waiting : .open,
                               createdAt: now, sourceType: draft.sourceType, personId: personId,
                               priority: draft.priority, details: draft.details, notes: draft.notes,
                               promisedAt: draft.capturedAt, nextAction: draft.nextAction,
                               waitingOnText: draft.startAsWaiting ? draft.waitingOn : nil,
                               waitingSince: draft.startAsWaiting ? now : nil,
                               aiExtractionVersion: draft.engineId,
                               aiConfidenceIndicators: draft.uncertainFields.map(\.rawValue).sorted(),
                               requiresReview: false)
            if !draft.startAsWaiting, let waiting = draft.waitingOn {
                c.waitingOnText = waiting
            }
            if let due = draft.selectedDue { c.apply(due: due, baseCalendar: calendar) }
            else { c.agreedDueText = draft.dateResolution.phrase }
            db.commitments[c.id] = c
            if let token = creationToken { db.creationTokens[token] = c.id }
            Self.log(&db, c.id, .created, now, draft.sourceType, ["title": c.title])
            if let pid = personId, let name = db.people[pid]?.displayName {
                Self.log(&db, c.id, .personLinked, now, draft.sourceType, ["person": name])
            }
            return SaveOutcome(commitment: c, created: true)
        }
        if outcome.created { onChange?() }
        return outcome
    }

    /// Saves several drafts independently; failures do not roll back earlier successes
    /// and are reported per draft (edge case 17).
    public func saveAll(_ drafts: [DraftCommitment]) -> [(draftId: UUID, result: Result<Commitment, Error>)] {
        drafts.map { d in
            do { return (d.id, .success(try save(d).commitment)) }
            catch { return (d.id, .failure(error)) }
        }
    }

    // MARK: Edit

    public struct Edit: Sendable {
        public var title: String?
        public var details: String??
        public var notes: String??
        public var personId: UUID??
        public var priority: Priority?
        public var nextAction: String??
        public var tags: [String]?
        public var isPinned: Bool?
        public var isSensitive: Bool?
        public var customReminders: [Date]?
        public var waitingCheckinDays: Int??
        public init(title: String? = nil, details: String?? = nil, notes: String?? = nil, personId: UUID?? = nil,
                    priority: Priority? = nil, nextAction: String?? = nil, tags: [String]? = nil, isPinned: Bool? = nil,
                    isSensitive: Bool? = nil, customReminders: [Date]? = nil, waitingCheckinDays: Int?? = nil) {
            self.title = title
            self.details = details
            self.notes = notes
            self.personId = personId
            self.priority = priority
            self.nextAction = nextAction
            self.tags = tags
            self.isPinned = isPinned
            self.isSensitive = isSensitive
            self.customReminders = customReminders
            self.waitingCheckinDays = waitingCheckinDays
        }
    }

    @discardableResult
    public func edit(_ id: UUID, _ edit: Edit, source: SourceType = .manual) throws -> Commitment {
        let now = clock.now
        let result: Commitment = try database.write { db in
            guard var c = db.commitments[id] else { throw DatabaseError.notFound }
            var changed: [String] = []
            if let t = edit.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, t != c.title { c.title = t; changed.append("title") }
            if let d = edit.details, d != c.details { c.details = d; changed.append("details") }
            if let n = edit.notes, n != c.notes { c.notes = n; changed.append("notes") }
            if let p = edit.priority, p != c.priority { c.priority = p; changed.append("priority") }
            if let n = edit.nextAction, n != c.nextAction { c.nextAction = n; changed.append("nextAction") }
            if let t = edit.tags, t != c.tags { c.tags = t; changed.append("tags") }
            if let p = edit.isPinned, p != c.isPinned { c.isPinned = p; changed.append("pinned") }
            if let s = edit.isSensitive, s != c.isSensitive { c.isSensitive = s; changed.append("sensitive") }
            if let r = edit.customReminders, r != c.customReminders { c.customReminders = r; changed.append("reminders") }
            if let w = edit.waitingCheckinDays, w != c.waitingCheckinDays { c.waitingCheckinDays = w; changed.append("checkins") }
            if let p = edit.personId, p != c.personId {
                c.personId = p
                if let pid = p, let name = db.people[pid]?.displayName {
                    Self.log(&db, id, .personLinked, now, source, ["person": name])
                }
                changed.append("person")
            }
            guard !changed.isEmpty else { return c }
            c.updatedAt = now
            c.revision += 1
            db.commitments[id] = c
            Self.log(&db, id, .edited, now, source, ["fields": changed.joined(separator: ",")])
            return c
        }
        onChange?()
        return result
    }

    /// Every reschedule logs the old and new values (FR-04).
    @discardableResult
    public func reschedule(_ id: UUID, to due: Commitment.Due?, source: SourceType = .manual) throws -> Commitment {
        let now = clock.now
        let result: Commitment = try database.write { db in
            guard var c = db.commitments[id] else { throw DatabaseError.notFound }
            let old = Self.describe(c.due)
            let newDue = due ?? .none(phrase: nil)
            c.apply(due: newDue, baseCalendar: calendar)
            let new = Self.describe(c.due)
            guard old != new else { return c }
            c.snoozedUntil = nil
            c.updatedAt = now
            c.revision += 1
            db.commitments[id] = c
            Self.log(&db, id, .rescheduled, now, source, ["from": old, "to": new])
            return c
        }
        onChange?()
        return result
    }

    /// Re-anchors a deadline's wall-clock time in a new time zone (explicit user choice
    /// after travel; edge case 9). Never happens automatically.
    @discardableResult
    public func moveDeadline(_ id: UUID, toTimeZone tzId: String) throws -> Commitment {
        guard let c = commitment(id) else { throw DatabaseError.notFound }
        var due = c.due
        due.timezoneId = tzId
        return try reschedule(id, to: due)
    }

    // MARK: Status

    @discardableResult
    public func setStatus(_ id: UUID, _ status: CommitmentStatus, reason: String? = nil, source: SourceType = .manual) throws -> Commitment {
        let now = clock.now
        var didChange = false
        let result: Commitment = try database.write { db in
            guard var c = db.commitments[id] else { throw DatabaseError.notFound }
            // Idempotent: repeating the same status is a no-op with no extra history.
            guard c.status != status else { return c }
            guard c.status.canTransition(to: status) else { throw DatabaseError.invalidTransition(from: c.status, to: status) }
            let old = c.status
            c.status = status
            c.updatedAt = now
            c.revision += 1
            c.snoozedUntil = nil
            switch status {
            case .completed:
                c.completedAt = now
            case .cancelled:
                c.cancelledAt = now
                c.cancelReason = reason
            case .waiting:
                c.waitingSince = now
            case .open:
                if old == .completed || old == .cancelled || old == .archived {
                    c.completedAt = nil
                    c.cancelledAt = nil
                    c.cancelReason = nil
                }
            default: break
            }
            db.commitments[id] = c
            let type: ActivityEventType
            switch (old, status) {
            case (_, .completed): type = .completed
            case (.completed, .open), (.cancelled, .open), (.archived, .open): type = .reopened
            default: type = .statusChanged
            }
            var payload = ["from": old.rawValue, "to": status.rawValue]
            if let reason { payload["reason"] = reason }
            Self.log(&db, id, type, now, source, payload)
            didChange = true
            return c
        }
        if didChange { onChange?() }
        return result
    }

    @discardableResult
    public func complete(_ id: UUID, source: SourceType = .manual) throws -> Commitment {
        try setStatus(id, .completed, source: source)
    }

    @discardableResult
    public func reopen(_ id: UUID, source: SourceType = .manual) throws -> Commitment {
        try setStatus(id, .open, source: source)
    }

    @discardableResult
    public func markWaiting(_ id: UUID, on text: String?, personId: UUID? = nil, source: SourceType = .manual) throws -> Commitment {
        let now = clock.now
        let result: Commitment = try database.write { db in
            guard var c = db.commitments[id] else { throw DatabaseError.notFound }
            guard c.status.canTransition(to: .waiting) else { throw DatabaseError.invalidTransition(from: c.status, to: .waiting) }
            let old = c.status
            c.status = .waiting
            c.waitingOnText = text ?? c.waitingOnText
            c.waitingOnPersonId = personId ?? c.waitingOnPersonId
            c.waitingSince = old == .waiting ? (c.waitingSince ?? now) : now
            c.updatedAt = now
            c.revision += 1
            db.commitments[id] = c
            Self.log(&db, id, .statusChanged, now, source, ["from": old.rawValue, "to": "waiting", "on": text ?? ""])
            return c
        }
        onChange?()
        return result
    }

    /// Snooze moves only the next reminder; the agreed deadline is preserved (§10.7).
    @discardableResult
    public func snooze(_ id: UUID, until: Date, source: SourceType = .manual) throws -> Commitment {
        let now = clock.now
        guard until > now else { throw DatabaseError.validation("Choose a time in the future.") }
        let result: Commitment = try database.write { db in
            guard var c = db.commitments[id] else { throw DatabaseError.notFound }
            guard c.status.isActive else { return c }
            c.snoozedUntil = until
            c.updatedAt = now
            c.revision += 1
            db.commitments[id] = c
            Self.log(&db, id, .snoozed, now, source, ["until": ISO8601DateFormatter().string(from: until)])
            return c
        }
        onChange?()
        return result
    }

    public func snooze(_ id: UUID, minutes: Int, source: SourceType = .manual) throws -> Commitment {
        try snooze(id, until: clock.now.addingTimeInterval(TimeInterval(minutes * 60)), source: source)
    }

    @discardableResult
    public func duplicate(_ id: UUID) throws -> Commitment {
        let now = clock.now
        let result: Commitment = try database.write { db in
            guard let original = db.commitments[id] else { throw DatabaseError.notFound }
            let active = db.commitments.values.filter { $0.status.isActive }.count
            guard entitlements.canCreateCommitment(activeCount: active) else { throw DatabaseError.limitReached(entitlements.commitmentLimitMessage) }
            var copy = original
            copy.id = UUID()
            copy.status = .open
            copy.createdAt = now
            copy.updatedAt = now
            copy.promisedAt = now
            copy.completedAt = nil
            copy.cancelledAt = nil
            copy.cancelReason = nil
            copy.snoozedUntil = nil
            copy.revision = 1
            copy.parentCommitmentId = original.id
            db.commitments[copy.id] = copy
            Self.log(&db, copy.id, .created, now, .manual, ["duplicatedFrom": original.title])
            return copy
        }
        onChange?()
        return result
    }

    /// Deletes the promise and its history; leaves a content-free tombstone event.
    public func delete(_ id: UUID) throws {
        let now = clock.now
        let removed: Bool = try database.write { db in
            guard db.commitments.removeValue(forKey: id) != nil else { return false }
            db.events.removeAll { $0.commitmentId == id }
            db.creationTokens = db.creationTokens.filter { $0.value != id }
            Self.log(&db, id, .deleted, now, .manual, [:])
            return true
        }
        if removed { onChange?() }
    }

    public func recordReminderDelivered(_ reminderId: String) {
        guard let id = ReminderPlanner.commitmentId(fromReminderId: reminderId) else { return }
        let now = clock.now
        try? database.write { db in
            guard db.commitments[id] != nil else { return }
            Self.log(&db, id, .reminded, now, .manual, ["reminder": reminderId])
        }
    }

    public func recordFollowUpDrafted(_ id: UUID) {
        let now = clock.now
        try? database.write { db in
            guard db.commitments[id] != nil else { return }
            Self.log(&db, id, .followupDrafted, now, .manual, [:])
        }
    }

    // MARK: People

    @discardableResult
    public func createPerson(named name: String, notes: String? = nil) throws -> Person {
        let now = clock.now
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DatabaseError.validation("Add a name.") }
        let p: Person = try database.write { db in
            let id = try Self.findOrCreatePerson(named: trimmed, in: &db, now: now, entitlements: entitlements, reuseExisting: false)
            if let notes { db.people[id]?.notes = notes }
            return db.people[id]!
        }
        onChange?()
        return p
    }

    @discardableResult
    public func updatePerson(_ id: UUID, displayName: String? = nil, aliases: [String]? = nil, notes: String?? = nil,
                             isArchived: Bool? = nil) throws -> Person {
        let p: Person = try database.write { db in
            guard var p = db.people[id] else { throw DatabaseError.notFound }
            if let n = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
                p.displayName = n
                p.normalizedName = TextNormalizer.normalize(n)
            }
            if let a = aliases { p.aliases = a.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            if let n = notes { p.notes = n }
            if let a = isArchived { p.isArchived = a }
            db.people[id] = p
            return p
        }
        onChange?()
        return p
    }

    /// Explicit merge chosen by the user. Commitments move to `target`; the source keeps
    /// its record (marked merged) and its name becomes an alias.
    public func mergePeople(source: UUID, into target: UUID) throws {
        guard source != target else { return }
        let now = clock.now
        try database.write { db in
            guard var s = db.people[source], var t = db.people[target] else { throw DatabaseError.notFound }
            for (id, var c) in db.commitments where c.personId == source || c.waitingOnPersonId == source {
                if c.personId == source { c.personId = target }
                if c.waitingOnPersonId == source { c.waitingOnPersonId = target }
                c.revision += 1
                c.updatedAt = now
                db.commitments[id] = c
                Self.log(&db, id, .personLinked, now, .manual, ["person": t.displayName, "mergedFrom": s.displayName])
            }
            let newAliases = ([s.displayName] + s.aliases).filter { TextNormalizer.normalize($0) != t.normalizedName && !t.aliases.contains($0) }
            t.aliases.append(contentsOf: newAliases)
            s.mergedIntoId = target
            s.isArchived = true
            db.people[source] = s
            db.people[target] = t
        }
        onChange?()
    }

    /// Deleting a person keeps commitments readable: the name is preserved in context
    /// and the link removed (edge case 16).
    public func deletePerson(_ id: UUID, reassignTo newId: UUID? = nil) throws {
        let now = clock.now
        try database.write { db in
            guard let p = db.people.removeValue(forKey: id) else { throw DatabaseError.notFound }
            for (cid, var c) in db.commitments where c.personId == id || c.waitingOnPersonId == id {
                if c.personId == id {
                    c.personId = newId
                    if newId == nil { c.context = [c.context, "For \(p.displayName)"].compactMap { $0 }.joined(separator: "\n") }
                }
                if c.waitingOnPersonId == id { c.waitingOnPersonId = newId; c.waitingOnText = c.waitingOnText ?? p.displayName }
                c.revision += 1
                c.updatedAt = now
                db.commitments[cid] = c
            }
        }
        onChange?()
    }

    // MARK: Settings & data

    public func updateSettings(_ change: (inout AppSettings) -> Void) throws {
        try database.write { change(&$0.settings) }
        onChange?()
    }

    public var userDisplayName: String? { database.read { $0.userDisplayName } }

    public func setUserDisplayName(_ name: String?) throws {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        try database.write { $0.userDisplayName = (trimmed?.isEmpty ?? true) ? nil : trimmed }
    }

    public func eraseAllData() throws {
        try database.eraseAll()
        onChange?()
    }

    // MARK: Internals

    static func findOrCreatePerson(named name: String, in db: inout DatabaseSnapshot, now: Date,
                                   entitlements: EntitlementPolicy, reuseExisting: Bool = true) throws -> UUID {
        let normalized = TextNormalizer.normalize(name)
        if reuseExisting, let existing = db.people.values.first(where: { $0.mergedIntoId == nil && !$0.isArchived && $0.searchableNames.contains(normalized) }) {
            return existing.id
        }
        let count = db.people.values.filter { !$0.isArchived && $0.mergedIntoId == nil }.count
        guard entitlements.canCreatePerson(count: count) else { throw DatabaseError.limitReached(entitlements.peopleLimitMessage) }
        let person = Person(displayName: name, createdAt: now)
        db.people[person.id] = person
        return person.id
    }

    static func log(_ db: inout DatabaseSnapshot, _ id: UUID, _ type: ActivityEventType, _ at: Date, _ source: SourceType, _ payload: [String: String]) {
        db.events.append(ActivityEvent(commitmentId: id, eventType: type, occurredAt: at, source: source, payload: payload))
    }

    static func describe(_ due: Commitment.Due) -> String {
        guard let local = due.local else { return due.precision == .none ? "none" : due.precision.rawValue }
        var s = "\(due.precision.rawValue):\(local.isoString)"
        if let end = due.windowEnd { s += "..\(end.isoString)" }
        return s + "@\(due.timezoneId)"
    }
}
