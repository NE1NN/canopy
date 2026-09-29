import Foundation

/// A ticket's channel name, or a row's title, taken apart: `ticket-0853-sameergoyal`, `closed-0853-sameergoyal`, and
/// `0853-sameergoyal` all have the number 853 and the customer `sameergoyal`.
public struct TicketName: Sendable, Equatable {
    public var number: Int?
    /// As written, such as "0853", for labels.
    public var digits: String?
    public var customer: String?

    init(number: Int?, digits: String?, customer: String?) {
        self.number = number
        self.digits = digits
        self.customer = customer
    }

    public init(_ name: String) {
        let rest = Self.withoutPrefix(name)
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, let number = Int(digits) else {
            self.init(number: nil, digits: nil, customer: nil)
            return
        }
        let after = rest.dropFirst(digits.count)
        let customer: String? = after.hasPrefix("-") && after.count > 1 ? String(after.dropFirst()) : nil
        guard after.isEmpty || customer != nil else {
            self.init(number: nil, digits: nil, customer: nil)
            return
        }
        self.init(number: number, digits: String(digits), customer: customer)
    }

    /// A row's title and folder name: the name without `ticket-` or `closed-`.
    public static func rowTitle(for name: String) -> String {
        String(withoutPrefix(name))
    }

    /// `#0853`, or nil for a name without a number.
    public static func label(for name: String) -> String? {
        TicketName(name).digits.map { "#" + $0 }
    }

    private static func withoutPrefix(_ name: String) -> Substring {
        for prefix in ["ticket-", "closed-"] where name.hasPrefix(prefix) {
            return name.dropFirst(prefix.count)
        }
        return Substring(name)
    }
}

/// What an agent typed to name a ticket.
public enum TicketReference: Sendable, Equatable {
    /// `853`, `0853`, `#0853`, `0853-sameergoyal`, `ticket-0853-sameergoyal`, or `closed-0853-sameergoyal`.
    case number(Int, customer: String?)
    /// Anything else is taken as a ticket-manager id.
    case id(String)

    /// Nil for blank text.
    public init?(_ text: String) {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("#") { text.removeFirst() }
        let name = TicketName(text)
        if let number = name.number {
            self = .number(number, customer: name.customer)
        } else {
            self = .id(text)
        }
    }

    /// Whether this names the ticket with this channel name or row title. An id never matches a name.
    public func matches(_ name: String) -> Bool {
        guard case .number(let number, let customer) = self else { return false }
        let other = TicketName(name)
        guard other.number == number else { return false }
        guard let customer else { return true }
        return other.customer?.caseInsensitiveCompare(customer) == .orderedSame
    }
}

/// Picks the one ticket a reference names from what the plugin found. The plugin looks at the rows' tickets and open
/// tickets first, then at closed and archived ones, one stage at a time.
public enum TicketResolution {
    public struct Candidate: Sendable, Equatable {
        public var id: String
        /// The channel name, or a row's title.
        public var name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    public enum Outcome: Sendable, Equatable {
        case found(String)
        /// Nothing in this stage: look in the next one.
        case none
    }

    /// The one ticket the reference matches among `candidates`, which may list a ticket more than once. Throws
    /// `.ambiguous` when it matches more than one ticket.
    public static func pick(_ reference: TicketReference, text: String, among candidates: [Candidate]) throws
        -> Outcome
    {
        let matches = candidates.filter { candidate in
            if case .id(let id) = reference { return candidate.id == id }
            return reference.matches(candidate.name)
        }
        var names: [String: String] = [:]
        for match in matches where names[match.id] == nil {
            names[match.id] = TicketName.rowTitle(for: match.name)
        }
        switch names.count {
        case 0: return .none
        case 1: return .found(names.keys.first!)
        default: throw TicketError.ambiguous(text, names.values.sorted())
        }
    }
}
