import Foundation
import Observation
import PromiseCore
import SwiftUI

enum AppTab: Hashable { case home, people, add, calendar, settings }

/// Navigation destinations shared by all stacks.
enum Route: Hashable {
    case commitment(UUID)
    case person(UUID)
    case history
    case impact
    case followUp(UUID)
}

/// How the capture sheet should open.
struct CaptureRequest: Identifiable, Equatable {
    enum Mode: Equatable { case voice, text, manual }
    let id = UUID()
    var mode: Mode
    var prefill: String = ""
    var personId: UUID?
    var source: SourceType = .voice
}

struct Toast: Identifiable {
    let id = UUID()
    let message: String
    let undo: (() -> Void)?
}

/// UI state for the whole app. Reads come from `PromiseService`; every mutation goes
/// back through it so App Intents and notification actions see the same data.
@MainActor
@Observable
final class AppModel {
    let env: AppEnvironment
    let store: StoreManager

    private(set) var commitments: [Commitment] = []
    private(set) var people: [Person] = []
    private(set) var settings = AppSettings()
    private(set) var userName: String?
    private(set) var now = Date()
    private(set) var notificationPermission: NotificationManager.Permission = .notDetermined
    private(set) var aiUnavailableReason: ExtractionUnavailableReason?

    var selectedTab: AppTab = .home
    var homePath = NavigationPath()
    var peoplePath = NavigationPath()
    var calendarPath = NavigationPath()
    var settingsPath = NavigationPath()
    var capture: CaptureRequest?
    var showPaywall = false
    var toast: Toast?
    var errorMessage: String?

    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    /// The live model, for App Intents that continue in the foreground.
    static weak var current: AppModel?

    init(env: AppEnvironment = .shared, store: StoreManager) {
        self.env = env
        self.store = store
        observer = NotificationCenter.default.addObserver(forName: .promiseDataChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        env.notifications.onOpenCommitment = { [weak self] id in
            Task { @MainActor in self?.open(.commitment(id)) }
        }
        store.onEntitlementChange = { [weak self] isPro in
            guard let self else { return }
            self.env.service.entitlements = EntitlementPolicy(isPro: isPro)
            self.env.notifications.scheduleReconcile()
        }
        reload()
        AppModel.current = self
    }

    var service: PromiseService { env.service }
    var isPro: Bool { store.isPro }
    var entitlements: EntitlementPolicy { EntitlementPolicy(isPro: isPro) }
    var calendar: Calendar { service.calendar }
    var classifier: CommitmentClassifier { CommitmentClassifier(calendar: .autoupdatingCurrent) }
    var formatter: DueFormatter { DueFormatter(calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent) }
    var showOnboarding: Bool { !settings.hasCompletedOnboarding }

    // MARK: Loading

    func reload() {
        now = Date()
        commitments = service.allCommitments()
        people = service.allPeople()
        settings = service.settings
        userName = service.userDisplayName
    }

    /// Foreground: refresh data, permissions, AI availability and the reminder queue.
    func didBecomeActive() async {
        reload()
        aiUnavailableReason = env.currentAIUnavailableReason()
        notificationPermission = await env.notifications.permission()
        await store.refreshEntitlements()
        service.entitlements = EntitlementPolicy(isPro: store.isPro)
        await env.notifications.reconcile()
        PromiseShortcuts.updateAppShortcutParameters()
    }

    func refreshPermissions() async {
        notificationPermission = await env.notifications.permission()
        aiUnavailableReason = env.currentAIUnavailableReason()
    }

    // MARK: Lookups

    func person(_ id: UUID?) -> Person? {
        guard let id else { return nil }
        return people.first { $0.id == id }
    }

    func personName(for c: Commitment) -> String? { person(c.personId)?.displayName }

    var activePeople: [Person] { people.filter { !$0.isArchived && $0.mergedIntoId == nil } }

    func commitment(_ id: UUID) -> Commitment? { commitments.first { $0.id == id } }

    func isOverdue(_ c: Commitment) -> Bool { classifier.isOverdue(c, now: now) }

    var digest: DigestSummary { DigestBuilder(calendar: .autoupdatingCurrent).summary(commitments, now: now) }

    func events(for id: UUID) -> [ActivityEvent] { service.events(for: id) }

    // MARK: Navigation

    func open(_ route: Route) {
        switch route {
        case .person:
            selectedTab = .people
            peoplePath = NavigationPath()
            peoplePath.append(route)
        default:
            selectedTab = .home
            homePath = NavigationPath()
            homePath.append(route)
        }
    }

    func startCapture(_ mode: CaptureRequest.Mode = .voice, prefill: String = "", personId: UUID? = nil, source: SourceType? = nil) {
        guard entitlements.canCreateCommitment(activeCount: service.activeCount) else {
            errorMessage = entitlements.commitmentLimitMessage
            showPaywall = true
            return
        }
        let src: SourceType = source ?? (mode == .voice ? .voice : (mode == .text ? .text : .manual))
        capture = CaptureRequest(mode: mode, prefill: prefill, personId: personId, source: src)
    }

    func handle(url: URL) {
        // promisetracker://capture  ·  promisetracker://commitment/<uuid>
        guard url.scheme == "promisetracker" else { return }
        switch url.host {
        case "capture":
            startCapture(.voice, source: .shortcut)
        case "commitment":
            let idString = url.pathComponents.dropFirst().first ?? ""
            // Only open records that exist locally; never echo arbitrary input.
            if let id = UUID(uuidString: idString), commitment(id) != nil { open(.commitment(id)) }
        default:
            break
        }
    }

    // MARK: Actions

    func perform(_ action: () throws -> Void) {
        do { try action() }
        catch { errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        reload()
    }

    func complete(_ c: Commitment) {
        perform { try service.complete(c.id) }
        showToast("Marked done") { [weak self] in self?.perform { try self?.service.reopen(c.id) } }
    }

    func reopen(_ c: Commitment) { perform { try service.reopen(c.id) } }

    func snooze(_ c: Commitment, until date: Date) {
        perform { try service.snooze(c.id, until: date) }
        showToast("Snoozed until \(date.formatted(date: .omitted, time: .shortened))", undo: nil)
    }

    func delete(_ c: Commitment) {
        perform { try service.delete(c.id) }
    }

    func showToast(_ message: String, undo: (() -> Void)?) {
        toastTask?.cancel()
        withAnimation { toast = Toast(message: message, undo: undo) }
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation { self?.toast = nil }
        }
    }

    func updateSettings(_ change: (inout AppSettings) -> Void) {
        perform { try service.updateSettings(change) }
    }

    func setUserName(_ name: String?) {
        perform { try service.setUserDisplayName(name) }
    }

    func completeOnboarding() {
        updateSettings { $0.hasCompletedOnboarding = true }
    }

    /// Asks for notification permission the first time a reminder matters.
    func ensureNotificationPermission() async {
        notificationPermission = await env.notifications.requestPermissionIfNeeded()
        if notificationPermission == .authorized { await env.notifications.reconcile() }
    }
}
