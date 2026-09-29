import Foundation

/// Says where JSON from ticket-manager stopped matching Canopy's models, such as "`tickets[37].number` is null, where
/// Canopy expects text (ticket closed-0079)".
enum UnreadableAnswer {
    /// `.unreadable` when the answer is ticket-manager's but something inside it does not fit, and `.badResponse`, with
    /// its hint to check the address, when the answer is not JSON or its top level is not ticket-manager's.
    static func error(_ error: DecodingError, body: Data, url: String) -> TicketError {
        guard (try? JSONSerialization.jsonObject(with: body)) != nil else {
            return .badResponse("its answer was not JSON", url: url)
        }
        if case .dataCorrupted = error { return .unreadable(reason(error, body: body), url: url) }
        guard let context = context(of: error), !context.codingPath.isEmpty else {
            return .badResponse(reason(error, body: body), url: url)
        }
        return .unreadable(reason(error, body: body), url: url)
    }

    static func reason(_ error: DecodingError, body: Data) -> String {
        let problem: String
        let path: [any CodingKey]
        switch error {
        case .valueNotFound(let type, let context):
            path = context.codingPath
            problem = "\(place(path)) is null, where Canopy expects \(words(for: type))"
        case .typeMismatch(let type, let context):
            path = context.codingPath
            problem = "\(place(path)) is not \(words(for: type))"
        case .keyNotFound(let key, let context):
            path = context.codingPath + [key]
            problem = "\(place(path)) is missing"
        case .dataCorrupted(let context):
            path = context.codingPath
            // Foundation reports a number that does not fit, such as 1.5 for an Int64, without its path.
            let detail =
                (context.underlyingError as NSError?)?.userInfo["NSDebugDescription"] as? String
                ?? context.debugDescription
            problem = path.isEmpty ? "a value does not fit: \(detail)" : "\(place(path)) is unreadable: \(detail)"
        @unknown default:
            return "\(error)"
        }
        guard let name = ticketName(at: path, in: body) else { return problem }
        return "\(problem) (ticket \(name))"
    }

    private static func context(of error: DecodingError) -> DecodingError.Context? {
        switch error {
        case .valueNotFound(_, let context), .typeMismatch(_, let context), .keyNotFound(_, let context),
            .dataCorrupted(let context):
            context
        @unknown default: nil
        }
    }

    private static func place(_ path: [any CodingKey]) -> String {
        guard !path.isEmpty else { return "the answer" }
        var text = ""
        for key in path {
            if let index = key.intValue {
                text += "[\(index)]"
            } else {
                text += (text.isEmpty ? "" : ".") + key.stringValue
            }
        }
        return "`\(text)`"
    }

    private static func words(for type: Any.Type) -> String {
        switch type {
        case is String.Type: "text"
        case is Int.Type, is Int64.Type: "a whole number"
        case is Double.Type: "a number"
        case is Bool.Type: "true or false"
        default:
            String(describing: type).hasPrefix("Array") ? "a list" : "an object"
        }
    }

    /// The channel name of the ticket the path runs through: `tickets[i]` in a list, or `ticket` in a detail.
    private static func ticketName(at path: [any CodingKey], in body: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let first = path.first
        else { return nil }
        let ticket: Any?
        switch first.stringValue {
        case "tickets":
            guard path.count > 1, let index = path[1].intValue, let list = root["tickets"] as? [Any],
                list.indices.contains(index)
            else { return nil }
            ticket = list[index]
        case "ticket", "messages":
            ticket = root["ticket"]
        default:
            return nil
        }
        return (ticket as? [String: Any])?["name"] as? String
    }
}
