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
