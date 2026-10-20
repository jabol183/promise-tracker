import Foundation
import OSLog
import PromiseCore

extension Notification.Name {
    static let promiseDataChanged = Notification.Name("PromiseTracker.dataChanged")
}

/// Process-wide dependencies shared by the UI, App Intents and notification actions,
/// so every entry point uses the same authoritative store (PRD §9 invariants).
final class AppEnvironment: @unchecked Sendable {
    static let shared = AppEnvironment()
    static let log = Logger(subsystem: "com.jabol183.PromiseTracker", category: "app")

    let service: PromiseService
    let notifications: NotificationManager
    /// Set when the store couldn't be opened safely; the UI shows a blocking message.
    let startupError: String?
    let recoveryNotice: String?

    private init() {
        let url = FileSnapshotStorage.defaultURL(appGroup: nil)
        var startupError: String?
        let database: PromiseDatabase
        do {
            database = try PromiseDatabase(storage: FileSnapshotStorage(url: url))
        } catch {
            // Never overwrite a file we can't read (e.g. from a newer version).
            startupError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            database = try! PromiseDatabase(storage: InMemorySnapshotStorage())
            // Content is never logged; only the failure class.
            Self.log.error("Store failed to open: \(String(describing: type(of: error)), privacy: .public)")
        }
        self.startupError = startupError
        self.recoveryNotice = database.recoveryNotice?.errorDescription
        service = PromiseService(database: database, calendar: .autoupdatingCurrent)
        notifications = NotificationManager()
        notifications.environment = self
        service.onChange = { [weak self] in
            self?.notifications.scheduleReconcile()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .promiseDataChanged, object: nil)
            }
        }
    }

    /// Whether the user allowed on-device AI (Settings › Preferences). Defaults to on.
    var aiEnabledByUser: Bool {
        UserDefaults.standard.object(forKey: "useOnDeviceAI") as? Bool ?? true
    }

    func currentAIUnavailableReason() -> ExtractionUnavailableReason? {
        aiEnabledByUser ? AIAvailability.unavailableReason() : .disabledByUser
    }

    func makeInterpreter() -> CaptureInterpreter {
        let settings = service.settings
        let resolver = DateResolver(calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent, preferences: settings.dates,
                                    lexicon: .english)
        return CaptureInterpreter(primary: aiEnabledByUser ? AIAvailability.makeExtractor() : nil, resolver: resolver)
    }

    /// Full pipeline for one capture, from any entry point.
    func interpret(_ text: String, source: SourceType, at date: Date = Date()) async -> CaptureResult {
        await makeInterpreter().interpret(text, source: source, capturedAt: date, people: service.allPeople(),
                                          existing: service.allCommitments(), unavailableReason: currentAIUnavailableReason())
    }
}
