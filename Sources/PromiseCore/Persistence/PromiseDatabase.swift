import Foundation

/// Everything the app stores. Versioned so migrations are explicit.
public struct DatabaseSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var commitments: [UUID: Commitment]
    public var people: [UUID: Person]
    public var events: [ActivityEvent]
    public var settings: AppSettings
    /// Idempotency tokens from Siri/Shortcuts → commitment created for them.
    public var creationTokens: [String: UUID]
    /// Local display name for greetings ("Good morning, Alex"). Never leaves the device.
    public var userDisplayName: String?

    public init() {
        schemaVersion = Self.currentSchemaVersion
        commitments = [:]
        people = [:]
        events = []
        settings = AppSettings()
        creationTokens = [:]
        userDisplayName = nil
    }
}

public enum DatabaseError: Error, Equatable, LocalizedError {
    /// The file was written by a newer app version; it is left untouched.
    case newerSchema(found: Int)
    /// The file could not be decoded; it was moved aside to `backupPath`.
    case corrupted(backupPath: String)
    /// Writing failed (e.g. device full). Nothing was changed.
    case writeFailed(String)
    case notFound
    case invalidTransition(from: CommitmentStatus, to: CommitmentStatus)
    case limitReached(String)
    case validation(String)

    public var errorDescription: String? {
        switch self {
        case let .newerSchema(v): return "Your data was saved by a newer version of Promise Tracker (format \(v)). Update the app to open it."
        case .corrupted: return "Your data file couldn’t be read. A copy was kept and a fresh store was started."
        case let .writeFailed(reason): return "Couldn’t save. Free up some space on your iPhone and try again. (\(reason))"
        case .notFound: return "That promise no longer exists."
        case let .invalidTransition(a, b): return "Can’t change a \(a.rawValue) promise to \(b.rawValue)."
        case let .limitReached(msg): return msg
        case let .validation(msg): return msg
        }
    }
}

/// Where snapshot bytes live. File-backed in the app; in-memory for tests/previews.
public protocol SnapshotStorage: AnyObject, Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
    /// Changes when another process (e.g. an App Intent extension) wrote the file.
    func changeToken() -> String?
    func moveAside(suffix: String) throws -> String?
    func erase() throws
}

public final class InMemorySnapshotStorage: SnapshotStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var version = 0
    public var failNextWrites = 0

    public init(data: Data? = nil) { self.data = data }

    public func load() throws -> Data? { lock.lock(); defer { lock.unlock() }; return data }
    public func save(_ d: Data) throws {
        lock.lock(); defer { lock.unlock() }
        if failNextWrites > 0 {
            failNextWrites -= 1
            throw CocoaError(.fileWriteOutOfSpace)
        }
        data = d
        version += 1
    }
    public func changeToken() -> String? { lock.lock(); defer { lock.unlock() }; return String(version) }
    public func moveAside(suffix: String) throws -> String? { lock.lock(); defer { lock.unlock() }; data = nil; return "memory-\(suffix)" }
    public func erase() throws { lock.lock(); defer { lock.unlock() }; data = nil; version += 1 }
}

public final class FileSnapshotStorage: SnapshotStorage, @unchecked Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Default location; uses the shared App Group container when one is configured so
    /// App Intents and (future) widgets read the same store.
    public static func defaultURL(appGroup: String?) -> URL {
        let fm = FileManager.default
        var base: URL
        #if os(iOS) || os(macOS) || os(watchOS) || os(visionOS)
        if let appGroup, let container = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            base = container
        } else {
            base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        }
        #else
        base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        #endif
        base.appendPathComponent("PromiseTracker", isDirectory: true)
        return base.appendingPathComponent("promises.json")
    }

    public func load() throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func save(_ data: Data) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS) || os(watchOS) || os(visionOS)
        // Encrypted at rest; readable after first unlock so reminders/intents work while locked.
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: [.atomic])
        #endif
    }

    public func changeToken() -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let date = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        return "\(date)-\(size)"
    }

    public func moveAside(suffix: String) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let dest = url.deletingPathExtension().appendingPathExtension("\(suffix).json")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: url, to: dest)
        return dest.path
    }

    public func erase() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

/// Transactional store. Every mutation runs on a copy and is committed in memory only
/// after the bytes are durably written, so a failed save leaves no partial state
/// (PRD edge case 14, acceptance 13).
public final class PromiseDatabase: @unchecked Sendable {
    private let storage: SnapshotStorage
    private let lock = NSRecursiveLock()
    private var snapshot: DatabaseSnapshot
    private var loadedToken: String?
    /// Set when startup had to recover from an unreadable file.
    public private(set) var recoveryNotice: DatabaseError?

    public init(storage: SnapshotStorage) throws {
        self.storage = storage
        self.snapshot = DatabaseSnapshot()
        try reload()
    }

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Reads from storage, applying migrations. Newer-schema files are never overwritten.
    public func reload() throws {
        lock.lock(); defer { lock.unlock() }
        guard let data = try storage.load() else {
            snapshot = DatabaseSnapshot()
            loadedToken = storage.changeToken()
            return
        }
        do {
            snapshot = try SchemaMigrator.migrate(data, decoder: Self.makeDecoder())
            loadedToken = storage.changeToken()
        } catch let error as DatabaseError {
            // Never overwrite a file we don't understand (e.g. written by a newer version).
            throw error
        } catch {
            let stamp = String(Int(Date().timeIntervalSince1970))
            let path = (try? storage.moveAside(suffix: "unreadable-\(stamp)")) ?? nil
            snapshot = DatabaseSnapshot()
            loadedToken = storage.changeToken()
            recoveryNotice = .corrupted(backupPath: path ?? "")
        }
    }

    /// Picks up writes made by another process since our last load.
    private func refreshIfChangedExternally() {
        let token = storage.changeToken()
        if token != loadedToken { try? reload() }
    }

    public func read<T>(_ body: (DatabaseSnapshot) throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        refreshIfChangedExternally()
        return try body(snapshot)
    }

    @discardableResult
    public func write<T>(_ body: (inout DatabaseSnapshot) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        refreshIfChangedExternally()
        var working = snapshot
        let result = try body(&working)
        guard working != snapshot else { return result }
        let data: Data
        do { data = try Self.makeEncoder().encode(working) }
        catch { throw DatabaseError.writeFailed("encoding: \(error.localizedDescription)") }
        do { try storage.save(data) }
        catch { throw DatabaseError.writeFailed(error.localizedDescription) }
        snapshot = working
        loadedToken = storage.changeToken()
        return result
    }

    public func exportJSON() throws -> Data {
        let e = Self.makeEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try read { try e.encode($0) }
    }

    /// Replaces everything with an imported export (after validation).
    public func importJSON(_ data: Data) throws {
        let imported = try SchemaMigrator.migrate(data, decoder: Self.makeDecoder())
        try write { $0 = imported }
    }

    public func eraseAll() throws {
        lock.lock(); defer { lock.unlock() }
        try storage.erase()
        snapshot = DatabaseSnapshot()
        loadedToken = storage.changeToken()
    }
}

/// Explicit, ordered schema migrations.
public enum SchemaMigrator {
    struct VersionProbe: Decodable { let schemaVersion: Int? }

    public static func migrate(_ data: Data, decoder: JSONDecoder) throws -> DatabaseSnapshot {
        let version = (try decoder.decode(VersionProbe.self, from: data)).schemaVersion ?? 0
        if version > DatabaseSnapshot.currentSchemaVersion { throw DatabaseError.newerSchema(found: version) }
        var raw = data
        var v = version
        while v < DatabaseSnapshot.currentSchemaVersion {
            raw = try step(from: v, raw)
            v += 1
        }
        var snapshot = try decoder.decode(DatabaseSnapshot.self, from: raw)
        snapshot.schemaVersion = DatabaseSnapshot.currentSchemaVersion
        return snapshot
    }

    /// v0 → v1: pre-release files had no version field; structure is otherwise identical.
    static func step(from version: Int, _ data: Data) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        switch version {
        case 0:
            object["schemaVersion"] = 1
            if object["creationTokens"] == nil { object["creationTokens"] = [String: String]() }
        default:
            break
        }
        return try JSONSerialization.data(withJSONObject: object)
    }
}
