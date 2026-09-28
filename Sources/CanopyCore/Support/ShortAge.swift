import Foundation

/// How long ago something happened, in its largest whole unit, such as "2h ago", for lists where space is short.
public enum ShortAge {
    public static func text(_ date: Date, now: Date = .now) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        let day = 86400
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(seconds / 60)m ago"
        case ..<day: return "\(seconds / 3600)h ago"
        case ..<(7 * day): return "\(seconds / day)d ago"
        case ..<(30 * day): return "\(seconds / (7 * day))w ago"
        case ..<(365 * day): return "\(seconds / (30 * day))mo ago"
        default: return "\(seconds / (365 * day))y ago"
        }
    }

    /// An ISO 8601 time, or the text as it is when it is not one.
    public static func text(_ iso: String, now: Date = .now) -> String {
        guard let date = try? Date(iso, strategy: .iso8601) else { return iso }
        return text(date, now: now)
    }
}
