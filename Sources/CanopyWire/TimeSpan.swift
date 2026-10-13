import Foundation

/// A length of time as `canopy log --since` writes one: a count and a unit of s, m, h, d, or w, such as `30m`.
/// A bare count is seconds.
public enum TimeSpan {
    public static func seconds(_ text: String) -> Double? {
        let lowered = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard let match = lowered.wholeMatch(of: /(\d{1,6})([smhdw]?)/), let count = Double(match.1) else {
            return nil
        }
        let unit: Double =
            switch match.2 {
            case "m": 60
            case "h": 3600
            case "d": 86_400
            case "w": 604_800
            default: 1
            }
        return count * unit
    }
}
