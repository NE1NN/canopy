import Foundation

public enum RelativeTime {
    /// How long ago, as the inbox shows it: "now", "4m", "2h", "3d".
    public static func short(since: Double, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince1970 - since)
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3_600)h"
        default: return "\(seconds / 86_400)d"
        }
    }
}
