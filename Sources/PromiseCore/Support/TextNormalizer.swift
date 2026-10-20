import Foundation

public enum TextNormalizer {
    /// Case- and diacritic-insensitive form used for search and name matching
    /// ("Zoë", "ZOE" and "zoe" all normalize to "zoe"; "Łukasz" to "lukasz").
    public static func normalize(_ text: String) -> String {
        let folded = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            // Characters that do not decompose into base + diacritic.
            .replacingOccurrences(of: "ł", with: "l")
            .replacingOccurrences(of: "ø", with: "o")
            .replacingOccurrences(of: "ß", with: "ss")
            .replacingOccurrences(of: "đ", with: "d")
        let collapsed = folded.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Search tokens: normalized words with punctuation removed.
    public static func tokens(_ text: String) -> [String] {
        normalize(text)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Removes control characters (except newlines/tabs) and trims, bounding length.
    public static func sanitize(_ text: String, maxLength: Int) -> String {
        let scalars = text.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || !CharacterSet.controlCharacters.contains(scalar)
        }
        var cleaned = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count > maxLength {
            cleaned = String(cleaned.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
    }
}

/// Injectable time source so all date logic is deterministic in tests.
public protocol DateProvider: Sendable {
    var now: Date { get }
}

public struct SystemDateProvider: DateProvider {
    public init() {}
    public var now: Date { Date() }
}

public final class FixedDateProvider: DateProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    public init(_ date: Date) { current = date }
    public var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return current }
    }
    public func set(_ date: Date) { lock.lock(); current = date; lock.unlock() }
    public func advance(by seconds: TimeInterval) { lock.lock(); current += seconds; lock.unlock() }
}
