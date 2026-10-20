import AppIntents
import Foundation
import PromiseCore

// MARK: - Entities

struct PromiseEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Promise"
    static var defaultQuery = PromiseEntityQuery()

    let id: UUID
    let title: String
    let personName: String?
    let dueText: String

    var displayRepresentation: DisplayRepresentation {
        let subtitle = [personName, dueText].compactMap { $0 }.joined(separator: " · ")
        return DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)")
    }

    init(_ c: Commitment, service: PromiseService) {
        id = c.id
        title = c.title
        personName = c.personId.flatMap { service.person($0)?.displayName }
        dueText = DueFormatter(calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent).short(c, now: Date())
    }
}

struct PromiseEntityQuery: EntityStringQuery {
    private var service: PromiseService { AppEnvironment.shared.service }

    func entities(for identifiers: [UUID]) async throws -> [PromiseEntity] {
        identifiers.compactMap { service.commitment($0) }.map { PromiseEntity($0, service: service) }
    }

    func entities(matching string: String) async throws -> [PromiseEntity] {
        let open = service.allCommitments().filter { $0.status.isActive }
        return SearchService().search(SearchQuery(text: string), commitments: open, people: service.allPeople())
            .prefix(10).map { PromiseEntity($0, service: service) }
    }

    func suggestedEntities() async throws -> [PromiseEntity] {
        let open = service.allCommitments().filter { $0.status.isActive }
        return CommitmentClassifier(calendar: .autoupdatingCurrent).sorted(open, now: Date())
            .prefix(10).map { PromiseEntity($0, service: service) }
    }
}

struct PersonEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Person"
    static var defaultQuery = PersonEntityQuery()

    let id: UUID
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct PersonEntityQuery: EntityStringQuery {
    private var service: PromiseService { AppEnvironment.shared.service }

    func entities(for identifiers: [UUID]) async throws -> [PersonEntity] {
        identifiers.compactMap { service.person($0) }.map { PersonEntity(id: $0.id, name: $0.displayName) }
    }

    func entities(matching string: String) async throws -> [PersonEntity] {
        let q = TextNormalizer.normalize(string)
        return service.activePeople.filter { $0.searchableNames.contains { $0.contains(q) } }
            .map { PersonEntity(id: $0.id, name: $0.displayName) }
    }

    func suggestedEntities() async throws -> [PersonEntity] {
        service.activePeople.sorted { $0.displayName < $1.displayName }.map { PersonEntity(id: $0.id, name: $0.displayName) }
    }
}

enum PromiseListFilter: String, AppEnum {
    case all, today, overdue, waiting, upcoming

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Which promises"
    static var caseDisplayRepresentations: [PromiseListFilter: DisplayRepresentation] = [
        .all: "All open", .today: "Due today", .overdue: "Overdue", .waiting: "Waiting", .upcoming: "Upcoming",
    ]

    var smart: SmartFilter {
        switch self {
        case .all: return .all
        case .today: return .today
        case .overdue: return .overdue
        case .waiting: return .waiting
        case .upcoming: return .upcoming
        }
    }
}

// MARK: - Intents

/// "Add a promise in Promise Tracker". Saves directly only when the user enabled quick
/// save and nothing needs review; otherwise continues in the app for review.
struct AddPromiseIntent: AppIntent, ForegroundContinuableIntent {
    static var title: LocalizedStringResource = "Add Promise"
    static var description = IntentDescription("Capture something you promised. Anything unclear opens Promise Tracker for review.")

    @Parameter(title: "What did you promise?", requestValueDialog: "What did you promise?")
    var text: String

    init() {}
    init(text: String) { self.text = text }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let env = AppEnvironment.shared
        let service = env.service
        guard service.entitlements.canCreateCommitment(activeCount: service.activeCount) else {
            return .result(dialog: "You have \(EntitlementPolicy.freeActiveCommitmentLimit) open promises, the free limit. Complete one or upgrade in the app.")
        }
        let now = Date()
        let result = await env.interpret(text, source: .siri, at: now)

        if service.settings.siriQuickSave, result.drafts.count == 1, let draft = result.drafts.first,
           draft.canSave, !draft.requiresReview, result.skipped.isEmpty {
            // Same words within the same minute = a retried request, not a new promise.
            let token = "siri:\(TextNormalizer.normalize(text)):\(Int(now.timeIntervalSince1970 / 60))"
            let outcome = try service.save(draft, creationToken: token)
            let c = outcome.commitment
            let who = c.personId.flatMap { service.person($0)?.displayName }.map { " for \($0)" } ?? ""
            let when = c.hasDeadline ? ", " + DueFormatter().short(c, now: now) : ""
            return .result(dialog: "Saved: \(c.title)\(who)\(when).")
        }

        if result.drafts.isEmpty {
            if let skipped = result.skipped.first {
                return .result(dialog: "\(skipped.explanation)")
            }
        }

        let words = text
        try await requestToContinueInForeground("Let’s review it in Promise Tracker.") {
            AppModel.current?.startCapture(.text, prefill: words, source: .siri)
        }
        return .result(dialog: "Opened Promise Tracker so you can check the details.")
    }
}

/// "What do I owe Anna in Promise Tracker?" — counts and titles from a deterministic query.
struct ShowPromisesIntent: AppIntent {
    static var title: LocalizedStringResource = "Show Promises"
    static var description = IntentDescription("Hear what you still owe, optionally for one person.")
    // Promise contents are personal: require an unlocked device.
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Person") var person: PersonEntity?
    @Parameter(title: "Which", default: .all) var filter: PromiseListFilter

    func perform() async throws -> some IntentResult & ReturnsValue<[PromiseEntity]> & ProvidesDialog {
        let service = AppEnvironment.shared.service
        let now = Date()
        let cls = CommitmentClassifier(calendar: .autoupdatingCurrent)
        var list = service.allCommitments().filter { cls.matches($0, filter: filter.smart, now: now) }
        if let person { list = list.filter { $0.personId == person.id } }
        list = cls.sorted(list, now: now)
        let entities = list.prefix(10).map { PromiseEntity($0, service: service) }

        guard !list.isEmpty else {
            if let person { return .result(value: [], dialog: "You don’t owe \(person.name) anything right now.") }
            return .result(value: [], dialog: "Nothing here right now.")
        }
        let fmt = DueFormatter(calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent)
        let items = list.prefix(3).map { c -> String in
            c.hasDeadline ? "\(c.title), \(fmt.short(c, now: now))" : c.title
        }
        let more = list.count > 3 ? ", and \(list.count - 3) more" : ""
        let lead = person.map { "You owe \($0.name) \(list.count) \(list.count == 1 ? "thing" : "things")" }
            ?? "You have \(list.count) \(list.count == 1 ? "promise" : "promises")"
        return .result(value: Array(entities), dialog: "\(lead): \(items.joined(separator: "; "))\(more).")
    }
}

/// Marks exactly one resolved promise done. Safe to run twice.
struct CompletePromiseIntent: AppIntent {
    static var title: LocalizedStringResource = "Mark Promise Complete"
    static var description = IntentDescription("Mark one promise as done and stop its reminders.")
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Promise") var promise: PromiseEntity

    init() {}
    init(promise: PromiseEntity) { self.promise = promise }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let service = AppEnvironment.shared.service
        guard let current = service.commitment(promise.id) else { return .result(dialog: "That promise no longer exists.") }
        if current.status == .completed { return .result(dialog: "“\(current.title)” is already done.") }
        try service.complete(promise.id, source: .siri)
        return .result(dialog: "Marked “\(current.title)” as done.")
    }
}

struct SnoozePromiseIntent: AppIntent {
    static var title: LocalizedStringResource = "Snooze Promise"
    static var description = IntentDescription("Move the next reminder later. The agreed deadline stays the same.")
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Promise") var promise: PromiseEntity
    @Parameter(title: "Minutes", default: 60, inclusiveRange: (5, 10_080)) var minutes: Int

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let service = AppEnvironment.shared.service
        guard let current = service.commitment(promise.id), current.status.isActive else {
            return .result(dialog: "That promise isn’t open.")
        }
        let c = try service.snooze(promise.id, minutes: minutes, source: .siri)
        let at = (c.snoozedUntil ?? Date()).formatted(date: .omitted, time: .shortened)
        return .result(dialog: "I’ll remind you about “\(c.title)” at \(at).")
    }
}

/// Opens straight into capture (good for the Action button).
struct OpenCaptureIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Capture"
    static var description = IntentDescription("Open Promise Tracker ready to listen.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.current?.startCapture(.voice, source: .shortcut)
        return .result()
    }
}

struct PromiseShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AddPromiseIntent(), phrases: [
            "Add a promise in \(.applicationName)",
            "Add a promise to \(.applicationName)",
            "Remember a promise with \(.applicationName)",
            "New promise in \(.applicationName)",
        ], shortTitle: "Add Promise", systemImageName: "plus.circle")
        AppShortcut(intent: ShowPromisesIntent(), phrases: [
            "What do I owe \(\.$person) in \(.applicationName)",
            "Show my promises in \(.applicationName)",
            "What do I owe in \(.applicationName)",
        ], shortTitle: "Show Promises", systemImageName: "list.bullet")
        AppShortcut(intent: OpenCaptureIntent(), phrases: [
            "Capture a promise with \(.applicationName)",
            "Open \(.applicationName) capture",
        ], shortTitle: "Open Capture", systemImageName: "mic")
        AppShortcut(intent: CompletePromiseIntent(), phrases: [
            "Mark a promise done in \(.applicationName)",
        ], shortTitle: "Mark Done", systemImageName: "checkmark.circle")
    }
}
