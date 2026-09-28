import Foundation

/// Reads the activity log files directly, so `canopy log` works while Canopy is not running.
public enum ActivityReader {
    /// Events from `since` up to but not including `until`, oldest first. `types` keeps events whose type is one of
    /// them, or starts with one and a dot, so "row" matches every row event.
    public static func events(in folder: URL, since: Date, until: Date?, types: [String] = []) -> [ActivityEvent] {
        // Files hold events by the local date they were recorded on, so a day either side covers a changed time zone.
        let first = ActivityLog.fileName(for: since.addingTimeInterval(-86_400))
        let last = until.map { ActivityLog.fileName(for: $0.addingTimeInterval(86_400)) }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { name in name.hasSuffix(".jsonl") && name >= first && last.map { name <= $0 } ?? true }
            .sorted()
        let decoder = JSONDecoder()
        var events: [(date: Date, event: ActivityEvent)] = []
        for name in names {
            guard let data = FileManager.default.contents(atPath: folder.appending(path: name).path) else { continue }
            var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
            // Whatever follows the last newline is a line the writer has not finished.
            lines.removeLast()
            for line in lines {
                let inRange = { (date: Date) in date >= since && until.map { date < $0 } ?? true }
                // Most lines of a day's file are outside a short range, so check the time before decoding the rest.
                if let date = timestamp(of: line), !inRange(date) { continue }
                guard let event = try? decoder.decode(ActivityEvent.self, from: Data(line)), let date = event.date,
                    inRange(date),
                    types.isEmpty || types.contains(where: { event.type == $0 || event.type.hasPrefix($0 + ".") })
                else { continue }
                events.append((date, event))
            }
        }
        // A moved clock can put an event in an earlier file than events recorded before it.
        return events.enumerated().sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }
            .map(\.element.event)
    }

    private static let prefix = Array(#"{"ts":""#.utf8)

    /// The time of a line the log wrote, which always starts with `ts`.
    private static func timestamp(of line: Data.SubSequence) -> Date? {
        guard line.starts(with: prefix) else { return nil }
        let start = line.index(line.startIndex, offsetBy: prefix.count)
        guard let end = line[start...].firstIndex(of: 0x22) else { return nil }
        return try? ActivityEvent.timestamp(in: .gmt).parse(String(decoding: line[start..<end], as: UTF8.self))
    }
}

public struct LogTimeError: Error, Equatable, CustomStringConvertible {
    public var text: String

    public var description: String {
        "Cannot read \"\(text)\" as a time. Use 30m, 2h, 3d, 1w, today, yesterday, 2026-09-27, 2026-09-27T14:30, or 14:30."
    }
}

/// The times `canopy log --since` and `--until` take: a span back from now, a day, a local date and time, a time today,
/// or a full ISO 8601 timestamp.
public enum LogTime {
    public static func parse(_ text: String, now: Date = Date(), timeZone: TimeZone = .current) throws -> Date {
        let calendar = Calendar.localGregorian(in: timeZone)
        let lowered = text.trimmingCharacters(in: .whitespaces).lowercased()
        switch lowered {
        case "now": return now
        case "today": return calendar.startOfDay(for: now)
        case "yesterday": return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) ?? now
        default: break
        }
        if let span = lowered.wholeMatch(of: /(\d{1,6})([smhdw])/), let count = Int(span.1) {
            let seconds = ["s": 1, "m": 60, "h": 3600][String(span.2)]
            if let seconds { return now.addingTimeInterval(-Double(count * seconds)) }
            let days = span.2 == "w" ? count * 7 : count
            if let date = calendar.date(byAdding: .day, value: -days, to: now) { return date }
        }
        if let match = lowered.wholeMatch(of: /(\d{4})-(\d{2})-(\d{2})(?:[t ](\d{1,2}):(\d{2})(?::(\d{2}))?)?/) {
            let parts = [match.1, match.2, match.3, match.4 ?? "0", match.5 ?? "0", match.6 ?? "0"].map {
                Int($0) ?? -1
            }
            if let date = local(parts, calendar) { return date }
        } else if let match = lowered.wholeMatch(of: /(\d{1,2}):(\d{2})(?::(\d{2}))?/) {
            let today = calendar.dateComponents([.year, .month, .day], from: now)
            let parts =
                [today.year ?? 0, today.month ?? 0, today.day ?? 0]
                + [match.1, match.2, match.3 ?? "0"].map { Int($0) ?? -1 }
            if let date = local(parts, calendar) { return date }
        } else {
            for fractional in [true, false] {
                let style = Date.ISO8601FormatStyle(timeZoneSeparator: .colon, includingFractionalSeconds: fractional)
                if let date = try? style.parse(text.trimmingCharacters(in: .whitespaces)) { return date }
            }
        }
        throw LogTimeError(text: text)
    }

    /// Year, month, day, hour, minute, and second as a local date, or nil if they name no real day, like the 31st of
    /// September. A time the clocks skip, as when daylight saving starts, moves forward to one that exists.
    private static func local(_ parts: [Int], _ calendar: Calendar) -> Date? {
        guard (0...23).contains(parts[3]), (0...59).contains(parts[4]), (0...59).contains(parts[5]) else { return nil }
        let components = DateComponents(
            year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4], second: parts[5])
        guard let date = calendar.date(from: components) else { return nil }
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        return [day.year, day.month, day.day] == parts.prefix(3).map(Optional.some) ? date : nil
    }
}

extension ActivityEvent {
    /// When it happened, in this machine's time zone, such as 2026-09-27 21:15:03.
    public var localTime: String {
        guard let date else { return ts }
        let parts = Calendar.localGregorian().dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d-%02d-%02d %02d:%02d:%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    /// What the event's data says, in a few words, for `canopy log`. Control characters show as `^[` and the like,
    /// so a command cannot break the table or reach the terminal.
    public var summary: String {
        String(
            details.unicodeScalars.flatMap { scalar -> [Character] in
                switch scalar.value {
                case 0x09: [" "]
                case 0x00..<0x20: ["^", Character(Unicode.Scalar(UInt8(scalar.value + 0x40)))]
                case 0x7F: ["^", "?"]
                default: [Character(scalar)]
                }
            })
    }

    private var details: String {
        let pane = text("pane") ?? ""
        switch type {
        case ActivityType.repoAdded, ActivityType.repoRemoved:
            return path ?? ""
        case ActivityType.rowCreated, ActivityType.rowAdopted, ActivityType.rowRemoved:
            return text("class") ?? ""
        case ActivityType.rowBranchChanged:
            return "\(text("from") ?? "detached") -> \(text("to") ?? "detached")"
        case ActivityType.prOpened:
            return "#\(number("number") ?? 0) \(text("state") ?? ""): \(text("title") ?? "") \(text("url") ?? "")"
        case ActivityType.prStateChanged:
            return "#\(number("number") ?? 0) \(text("from") ?? "") -> \(text("to") ?? "")"
        case ActivityType.termOpened:
            return pane
        case ActivityType.termExited:
            return "\(pane) exit \(number("code") ?? 0)"
        case ActivityType.termCommand:
            let took = number("durationMs").map { " in \(Self.duration(milliseconds: $0))" } ?? ""
            let command = (text("cmd") ?? "").replacingOccurrences(of: "\n", with: " \u{21b5} ")
            return "\(pane) exit \(number("exit") ?? 0)\(took): \(command)"
        case ActivityType.cliCall:
            var params = data["params"]
            if case .object(var fields) = params {
                fields["target"] = nil
                params = fields.isEmpty ? nil : .object(fields)
            }
            let failed = text("error").map { " failed: \($0)" } ?? ""
            return [text("method"), params.map(Self.compact)].compactMap { $0 }.joined(separator: " ") + failed
        default:
            return data.isEmpty ? "" : Self.compact(.object(data))
        }
    }

    private func text(_ key: String) -> String? {
        if case .string(let value) = data[key] { value } else { nil }
    }

    private func number(_ key: String) -> Int? {
        if case .number(let value) = data[key] { Int(value) } else { nil }
    }

    static func duration(milliseconds: Int) -> String {
        if milliseconds < 1000 { return "\(milliseconds)ms" }
        if milliseconds < 60_000 { return String(format: "%.1fs", Double(milliseconds) / 1000) }
        let seconds = milliseconds / 1000
        if seconds < 3600 { return String(format: "%dm%02ds", seconds / 60, seconds % 60) }
        return String(format: "%dh%02dm", seconds / 3600, seconds % 3600 / 60)
    }

    static func compact(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}
