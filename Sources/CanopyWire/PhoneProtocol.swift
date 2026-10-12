import Foundation

/// What the iPhone app calls on the Mac's phone listener.
public enum PhoneMethod {
    /// Authenticates the connection with the phone's device token. It must come first.
    public static let hello = "phone.hello"
    /// Trades a one-time pairing code for a device token. Allowed before `hello`.
    public static let pair = "phone.pair"
    /// Answers with the inbox, then sends `PhoneEvent.inbox` each time it changes.
    public static let subscribe = "phone.subscribe"
    /// Every row, by repo and plugin, with its agents and PR.
    public static let rows = "phone.rows"
    /// A page of a pane's conversation, then `PhoneEvent.transcript` as it grows, when following.
    public static let transcript = "phone.transcript"
    /// Pastes text into a pane and presses Return.
    public static let reply = "phone.reply"
    /// Answers the pane's open prompt.
    public static let answer = "phone.answer"
    /// The pane's screen with its colors, then `PhoneEvent.screen` as it changes.
    public static let screen = "phone.screen"
    /// Sends keys into a pane.
    public static let keys = "phone.keys"
    /// Marks a pane's done agent as seen.
    public static let seen = "phone.seen"
    /// Ends a stream another request started.
    public static let unsubscribe = "phone.unsubscribe"
}

/// Names a pane, for the methods that act on one.
public struct PhonePaneParams: Codable, Sendable, Equatable {
    public var pane: String

    public init(pane: String) {
        self.pane = pane
    }
}

public struct PhoneTranscriptParams: Codable, Sendable, Equatable {
    public var pane: String
    /// The `older` cursor of the page after this one. Nil for the newest page.
    public var before: Int?
    public var limit: Int
    /// Sends `PhoneEvent.transcript` as the conversation grows, until `phone.unsubscribe`.
    public var follow: Bool

    public init(pane: String, before: Int? = nil, limit: Int = 50, follow: Bool = false) {
        self.pane = pane
        self.before = before
        self.limit = limit
        self.follow = follow
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pane = try container.decode(String.self, forKey: .pane)
        before = try container.decodeIfPresent(Int.self, forKey: .before)
        limit = try container.decodeIfPresent(Int.self, forKey: .limit) ?? 50
        follow = try container.decodeIfPresent(Bool.self, forKey: .follow) ?? false
    }
}

public struct PhoneTranscriptResult: Codable, Sendable, Equatable {
    public var pane: String
    /// Oldest first.
    public var entries: [TranscriptEntry]
    /// The cursor for the next older page, or nil at the start.
    public var older: Int?

    public init(pane: String, entries: [TranscriptEntry], older: Int?) {
        self.pane = pane
        self.entries = entries
        self.older = older
    }
}

/// What a followed conversation sends as it grows: entries new or changed since the last, which replace any with the
/// same ID. `reset` means the pane moved to another session, so the phone drops what it had.
public struct PhoneTranscriptUpdate: Codable, Sendable, Equatable {
    public var pane: String
    public var entries: [TranscriptEntry]
    public var reset: Bool

    public init(pane: String, entries: [TranscriptEntry], reset: Bool = false) {
        self.pane = pane
        self.entries = entries
        self.reset = reset
    }
}

public struct PhoneReplyParams: Codable, Sendable, Equatable {
    public var pane: String
    public var text: String

    public init(pane: String, text: String) {
        self.pane = pane
        self.text = text
    }
}

public struct PhoneReplyResult: Codable, Sendable, Equatable {
    /// Names the reply in its `PhoneEvent.delivered`.
    public var reply: String

    public init(reply: String) {
        self.reply = reply
    }
}

/// The answer to an open prompt.
public struct PhoneAnswer: Codable, Sendable, Equatable {
    /// Allow or Deny for a permission prompt; approve or keep planning for a plan.
    public var allow: Bool?
    /// For questions, the chosen options of each question in order, counted from 0.
    public var options: [[Int]]?

    public init(allow: Bool? = nil, options: [[Int]]? = nil) {
        self.allow = allow
        self.options = options
    }
}

public struct PhoneAnswerParams: Codable, Sendable, Equatable {
    public var pane: String
    /// The open prompt's ID, so an answer never reaches a prompt that replaced it.
    public var prompt: String
    public var answer: PhoneAnswer

    public init(pane: String, prompt: String, answer: PhoneAnswer) {
        self.pane = pane
        self.prompt = prompt
        self.answer = answer
    }
}

public struct PhoneKeysParams: Codable, Sendable, Equatable {
    public var pane: String
    /// What to send, escape sequences and control characters included, such as `"\u{1b}"` for Escape.
    public var text: String

    public init(pane: String, text: String) {
        self.pane = pane
        self.text = text
    }
}

/// A pane's screen at the Mac's width. Lines carry SGR escape sequences for their colors and styles.
public struct PhoneScreen: Codable, Sendable, Equatable {
    public var pane: String
    public var columns: Int
    public var rows: Int
    /// Scrollback above the screen, oldest first. Sent with the first screen only.
    public var scrollback: [String]?
    /// The visible screen, top to bottom.
    public var lines: [String]

    public init(pane: String, columns: Int, rows: Int, scrollback: [String]? = nil, lines: [String]) {
        self.pane = pane
        self.columns = columns
        self.rows = rows
        self.scrollback = scrollback
        self.lines = lines
    }
}

public struct PhoneUnsubscribeParams: Codable, Sendable, Equatable {
    /// The ID of the request that started the stream.
    public var subscription: String

    public init(subscription: String) {
        self.subscription = subscription
    }
}

/// A reply reached the agent: its pane's next prompt arrived.
public struct PhoneDelivered: Codable, Sendable, Equatable {
    public var pane: String
    public var reply: String

    public init(pane: String, reply: String) {
        self.pane = pane
        self.reply = reply
    }
}

/// The port the Mac listens on for phones, on its Tailscale addresses.
public enum PhonePort {
    public static let standard: UInt16 = 6974
}

public struct PhoneHelloParams: Codable, Sendable, Equatable {
    public var token: String

    public init(token: String) {
        self.token = token
    }
}

public struct PhoneHelloResult: Codable, Sendable, Equatable {
    /// The Mac's name, as Sharing settings show it.
    public var mac: String
    /// Canopy's version.
    public var version: String
    /// The name the Mac knows this phone by.
    public var phone: String

    public init(mac: String, version: String, phone: String) {
        self.mac = mac
        self.version = version
        self.phone = phone
    }
}

public struct PhonePairParams: Codable, Sendable, Equatable {
    public var code: String
    /// The phone's name, such as "Hindie's iPhone".
    public var name: String

    public init(code: String, name: String) {
        self.code = code
        self.name = name
    }
}

public struct PhonePairResult: Codable, Sendable, Equatable {
    /// The device token the phone keeps and sends with every `hello`.
    public var token: String
    /// The name the Mac gave the phone, which differs from the one sent when another phone has it.
    public var phone: String
    public var mac: String

    public init(token: String, phone: String, mac: String) {
        self.token = token
        self.phone = phone
        self.mac = mac
    }
}

/// Something the Mac sends without being asked, for a stream a request started.
public struct PhoneEvent: Codable, Sendable, Equatable {
    /// The inbox changed. `data` is the new `PhoneInbox`.
    public static let inbox = "phone.inbox"
    /// A followed conversation grew. `data` is a `PhoneTranscriptUpdate`.
    public static let transcript = "phone.transcript"
    /// A watched screen changed. `data` is a `PhoneScreen`.
    public static let screen = "phone.screen"
    /// A reply reached its agent. `data` is a `PhoneDelivered`.
    public static let delivered = "phone.delivered"

    public var v: Int
    public var event: String
    /// The ID of the request that started the stream.
    public var subscription: String
    public var data: JSONValue

    public init(event: String, subscription: String, data: JSONValue, v: Int = ControlCodec.version) {
        self.v = v
        self.event = event
        self.subscription = subscription
        self.data = data
    }
}

/// One line from the Mac: the answer to a request, or an event.
public enum PhoneMessage: Sendable, Equatable {
    case response(ControlResponse)
    case event(PhoneEvent)

    private enum Keys: String, CodingKey {
        case event
    }

    public init(line: Data) throws {
        let decoder = JSONDecoder()
        let keys = try decoder.decode([String: JSONValue].self, from: line)
        if keys[Keys.event.rawValue] != nil {
            self = .event(try decoder.decode(PhoneEvent.self, from: line))
        } else {
            self = .response(try decoder.decode(ControlResponse.self, from: line))
        }
    }
}
