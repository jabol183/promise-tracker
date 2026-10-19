import Foundation

/// Spreadsheet-friendly export of all promises (FR-12). Always free.
public struct CSVExporter: Sendable {
    public init() {}

    public func export(commitments: [Commitment], people: [Person]) -> String {
        let names = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0.displayName) })
        let iso = ISO8601DateFormatter()
        let header = ["id", "title", "person", "status", "due_precision", "due_local", "due_window_end", "timezone",
                      "agreed_due_text", "priority", "waiting_on", "next_action", "notes", "original_input",
                      "created_at", "completed_at", "cancelled_at"]
        var rows = [header.joined(separator: ",")]
        for c in commitments.sorted(by: { $0.createdAt < $1.createdAt }) {
            let fields: [String?] = [
                c.id.uuidString, c.title, c.personId.flatMap { names[$0] }, c.status.rawValue, c.duePrecision.rawValue,
                c.dueLocal?.isoString, c.dueWindowEnd?.isoString, c.timezoneId, c.agreedDueText, c.priority.rawValue,
                c.waitingOnText, c.nextAction, c.notes, c.originalInput, iso.string(from: c.createdAt),
                c.completedAt.map(iso.string), c.cancelledAt.map(iso.string),
            ]
            rows.append(fields.map { escape($0 ?? "") }.joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    func escape(_ value: String) -> String {
        // Neutralize spreadsheet formula injection, then quote.
        var v = value
        if let first = v.first, "=+-@".contains(first) { v = "'" + v }
        if v.contains(",") || v.contains("\"") || v.contains("\n") || v.contains("'") {
            return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return v
    }
}
