import Foundation
import PromiseCore
import UserNotifications

/// Installs local reminders derived from commitment state and handles notification
/// actions. The OS queue is never the source of truth: it is reconciled against
/// `ReminderPlanner` output on launch, foreground and after every change (PRD §10).
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let categoryId = "PROMISE_REMINDER"
    static let digestCategoryId = "PROMISE_DIGEST"
    static let doneAction = "PROMISE_DONE"
    static let snoozeAction = "PROMISE_SNOOZE_1H"
    static let snoozeTomorrowAction = "PROMISE_SNOOZE_TOMORROW"
    static let openAction = "PROMISE_OPEN"

    private let center = UNUserNotificationCenter.current()
    private let reconcileLock = NSLock()
    private var reconcileTask: Task<Void, Never>?
    /// Called when the user taps a reminder (to open the promise).
    var onOpenCommitment: ((UUID) -> Void)?
    weak var environment: AppEnvironment?

    override init() {
        super.init()
        center.delegate = self
        registerCategories()
    }

    private func registerCategories() {
        // Done requires unlock so nobody can close promises from a locked phone.
        let done = UNNotificationAction(identifier: Self.doneAction, title: "Mark Done", options: [.authenticationRequired],
                                        icon: UNNotificationActionIcon(systemImageName: "checkmark"))
        let snooze = UNNotificationAction(identifier: Self.snoozeAction, title: "Snooze 1 hour", options: [],
                                          icon: UNNotificationActionIcon(systemImageName: "clock"))
        let tomorrow = UNNotificationAction(identifier: Self.snoozeTomorrowAction, title: "Tomorrow morning", options: [],
                                            icon: UNNotificationActionIcon(systemImageName: "sunrise"))
        let open = UNNotificationAction(identifier: Self.openAction, title: "Open", options: [.foreground])
        let reminder = UNNotificationCategory(identifier: Self.categoryId, actions: [done, snooze, tomorrow, open],
                                              intentIdentifiers: [], options: [])
        let digest = UNNotificationCategory(identifier: Self.digestCategoryId, actions: [open], intentIdentifiers: [], options: [])
        center.setNotificationCategories([reminder, digest])
    }

    // MARK: Permission

    enum Permission: Equatable { case notDetermined, denied, authorized }

    func permission() async -> Permission {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized, .provisional, .ephemeral: return .authorized
        @unknown default: return .denied
        }
    }

    /// Asked only when the user first saves a promise with a reminder (PRD §7.1).
    @discardableResult
    func requestPermissionIfNeeded() async -> Permission {
        let current = await permission()
        guard current == .notDetermined else { return current }
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        return granted ? .authorized : .denied
    }

    // MARK: Reconciliation

    /// Coalesces bursts of changes into one reconcile pass.
    func scheduleReconcile() {
        reconcileLock.lock()
        reconcileTask?.cancel()
        reconcileTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.reconcile()
        }
        reconcileLock.unlock()
    }

    func reconcile() async {
        guard let env = environment, await permission() == .authorized else { return }
        let service = env.service
        let now = Date()
        let settings = service.settings
        let planner = ReminderPlanner(settings: settings.reminders, calendar: service.calendar, isPro: service.entitlements.isPro)
        let commitments = service.allCommitments()
        let names = Dictionary(uniqueKeysWithValues: service.allPeople().map { ($0.id, $0.displayName) })
        var desired = commitments.flatMap { c in planner.plan(for: c, personName: c.personId.flatMap { names[$0] }, now: now) }
        desired += planner.digest(commitments: commitments, now: now)

        let pending = await center.pendingNotificationRequests()
        let plan = NotificationReconciler().reconcile(desired: desired, pendingIds: Set(pending.map(\.identifier)), now: now)
        if !plan.toRemove.isEmpty { center.removePendingNotificationRequests(withIdentifiers: plan.toRemove) }
        for rule in plan.toAdd {
            try? await center.add(request(for: rule))
        }
        await recordDelivered()
    }

    private func request(for rule: ReminderRule) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = rule.title
        content.body = rule.body
        content.sound = .default
        content.categoryIdentifier = rule.kind == .dailyDigest ? Self.digestCategoryId : Self.categoryId
        content.threadIdentifier = rule.commitmentId?.uuidString ?? "digest"
        var info: [String: String] = ["reminderId": rule.id, "kind": rule.kind.rawValue]
        if let id = rule.commitmentId { info["commitmentId"] = id.uuidString }
        content.userInfo = info

        // Absolute instant: components carry the current zone so travel can't shift it.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        var comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: rule.scheduledAt)
        comps.timeZone = .current
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        return UNNotificationRequest(identifier: rule.id, content: content, trigger: trigger)
    }

    /// Logs "reminded" history for notifications the OS delivered while we were away.
    private func recordDelivered() async {
        guard let env = environment else { return }
        let delivered = await center.deliveredNotifications()
        for n in delivered where n.request.identifier.hasPrefix(ReminderPlanner.idPrefix) {
            env.service.recordReminderDelivered(n.request.identifier)
        }
    }

    func removeAll() {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        environment?.service.recordReminderDelivered(notification.request.identifier)
        return [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let reminderId = response.notification.request.identifier
        environment?.service.recordReminderDelivered(reminderId)
        guard let idString = info["commitmentId"] as? String, let id = UUID(uuidString: idString),
              let service = environment?.service, service.commitment(id) != nil else { return }
        switch response.actionIdentifier {
        case Self.doneAction:
            _ = try? service.complete(id, source: .manual)
        case Self.snoozeAction:
            _ = try? service.snooze(id, minutes: 60)
        case Self.snoozeTomorrowAction:
            let time = service.settings.reminders.dateOnlyReminderTime
            let cal = service.calendar
            let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) ?? Date()
            let target = cal.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: tomorrow) ?? tomorrow
            _ = try? service.snooze(id, until: target)
        default:
            await MainActor.run { onOpenCommitment?(id) }
        }
    }
}
