import Foundation

/// How a chat's status line words times and token counts.
public enum ChatFormat {
    /// "41s", "1m 12s", "1h 3m".
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let rest = total % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(rest)s" }
        return "\(rest)s"
    }

    /// A clock for how long something has waited: "0:08", "12:30", "1:02:05".
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let rest = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, rest) }
        return String(format: "%d:%02d", minutes, rest)
    }

    /// "850", "2.3k", "41k", "1.2M".
    public static func tokens(_ count: Int) -> String {
        switch count {
        case ..<1000: return "\(count)"
        case ..<10_000: return trimmed(Double(count) / 1000) + "k"
        case ..<1_000_000: return "\(count / 1000)k"
        default: return trimmed(Double(count) / 1_000_000) + "M"
        }
    }

    /// "14% of context".
    public static func context(used: Int, window: Int) -> String {
        guard window > 0 else { return "" }
        let percent = Int((Double(used) / Double(window) * 100).rounded())
        return "\(min(100, max(0, percent)))% of context"
    }

    private static func trimmed(_ value: Double) -> String {
        let text = String(format: "%.1f", (value * 10).rounded(.down) / 10)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }
}
