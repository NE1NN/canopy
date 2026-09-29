import Foundation

/// Messages that share one header, as Discord groups them: one author's messages in one place, each within seven
/// minutes of the one before.
public struct MessageGroup: Sendable, Equatable, Identifiable {
    public var messages: [TicketMessage]
    public var author: MessageAuthor
    /// "in thread Shadowban check", or "in a thread" while the API has no name for it, or nil outside threads.
    public var threadLabel: String?

    /// The first message's id.
    public var id: String { messages[0].id }
    public var posted: Date { messages[0].posted }

    public static let window: TimeInterval = 420

    public static func groups(_ messages: [TicketMessage]) -> [MessageGroup] {
        var groups: [MessageGroup] = []
        for message in messages {
            if let last = groups.last?.messages.last, last.author.username == message.author.username,
                last.author.isBot == message.author.isBot, last.thread?.id == message.thread?.id,
                message.posted.timeIntervalSince(last.posted) <= window
            {
                groups[groups.count - 1].messages.append(message)
            } else {
                let label = message.thread.map { thread in
                    thread.name.flatMap { $0.isEmpty ? nil : "in thread \($0)" } ?? "in a thread"
                }
                groups.append(MessageGroup(messages: [message], author: message.author, threadLabel: label))
            }
        }
        return groups
    }
}

/// When a message was posted, as Discord writes it.
public enum MessageTime {
    /// "Today at 15:04", "Yesterday at 09:10", or "11 Sept 2026 at 14:13", in the locale's forms.
    public static func text(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String
    {
        var timeStyle = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        timeStyle = timeStyle.hour().minute()
        let time = date.formatted(timeStyle)
        if calendar.isDate(date, inSameDayAs: now) { return "Today at \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(date, inSameDayAs: yesterday)
        {
            return "Yesterday at \(time)"
        }
        let day = date.formatted(
            Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).day().month(.abbreviated)
                .year())
        return "\(day) at \(time)"
    }
}

extension MessageAttachment {
    public enum Kind: Sendable, Equatable {
        case image, file
    }

    public var kind: Kind {
        if contentType?.lowercased().hasPrefix("image/") == true { return .image }
        let ext = (filename as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(ext) ? .image : .file
    }

    /// Discord's signed links stop working at their `ex` time, a hex count of seconds since the epoch.
    public func isExpired(now: Date) -> Bool {
        guard let expiry = URLComponents(string: url)?.queryItems?.first(where: { $0.name == "ex" })?.value,
            let seconds = UInt64(expiry, radix: 16)
        else { return false }
        return Date(timeIntervalSince1970: TimeInterval(seconds)) <= now
    }

    /// "900 B", "47 KB", or "3.2 MB".
    public var sizeText: String {
        switch size {
        case ..<1024: return "\(size) B"
        case ..<(1024 * 1024): return "\(Int((Double(size) / 1024).rounded(.down))) KB"
        default: return String(format: "%.1f MB", Double(size) / (1024 * 1024))
        }
    }
}
