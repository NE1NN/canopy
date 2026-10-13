import CanopyWire
import Foundation

/// What the `canopy phone` commands call on the control socket. Phones themselves call `PhoneMethod`s.
public enum PhonesMethod {
    public static let pair = "phones.pair"
    public static let paired = "phones.paired"
    public static let list = "phones.list"
    public static let remove = "phones.remove"
    public static let status = "phones.status"
    /// Shows or sets what a task from the phone runs.
    public static let agent = "phones.agent"
}

public struct PhonesAgentParams: Codable, Sendable {
    /// The new command. Nil, without `reset`, only shows the one there is.
    public var command: String?
    /// Goes back to `PhoneAgentCommand.standard`.
    public var reset: Bool
    /// A host whose canopy-box runs the tasks, rather than this Mac.
    public var on: String?

    public init(command: String? = nil, reset: Bool = false, on: String? = nil) {
        self.command = command
        self.reset = reset
        self.on = on
    }
}

public struct PhonesAgentResult: Codable, Sendable, Equatable {
    public var command: String
    /// No command is set, so the standard one runs.
    public var isDefault: Bool
    public var on: String?

    public init(command: String, isDefault: Bool, on: String? = nil) {
        self.command = command
        self.isDefault = isDefault
        self.on = on
    }
}

/// A new pairing code and the link its QR code holds.
public struct PhonesPairResult: Codable, Sendable, Equatable {
    public var code: String
    /// A `canopy-phone://pair` URL.
    public var link: String
    /// Seconds since 1970.
    public var expires: Double

    public init(code: String, link: String, expires: Double) {
        self.code = code
        self.link = link
        self.expires = expires
    }
}

public struct PhonesPairedParams: Codable, Sendable {
    public var code: String
    /// A host whose canopy-box serves the phone, rather than this Mac.
    public var on: String?

    public init(code: String, on: String? = nil) {
        self.code = code
        self.on = on
    }
}

/// Which server a phone command is about: this Mac, or a host's canopy-box.
public struct PhonesOnParams: Codable, Sendable {
    public var on: String?

    public init(on: String? = nil) {
        self.on = on
    }
}

/// The phone that paired, or nil when the code expired unused.
public struct PhonesPairedResult: Codable, Sendable, Equatable {
    public var phone: PhoneInfo?

    public init(phone: PhoneInfo?) {
        self.phone = phone
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(phone, forKey: .phone)
    }
}

/// A paired phone, as `canopy phone list` shows it.
public struct PhoneInfo: Codable, Sendable, Equatable {
    public var name: String
    /// Seconds since 1970.
    public var pairedAt: Double
    public var lastConnected: Double?
    /// It has a connection open now.
    public var connected: Bool
    /// It registered for push notifications.
    public var notifications: Bool

    public init(_ phone: PairedPhone, connected: Bool) {
        name = phone.name
        pairedAt = phone.pairedAt.timeIntervalSince1970
        lastConnected = phone.lastConnected?.timeIntervalSince1970
        self.connected = connected
        notifications = phone.pushToken != nil
    }
}

public struct PhonesRemoveParams: Codable, Sendable {
    public var name: String
    public var on: String?

    public init(name: String, on: String? = nil) {
        self.name = name
        self.on = on
    }
}

public struct PhonesStatusResult: Codable, Sendable, Equatable {
    public static let noPushKey = "Off: no push key on this Mac."

    public var listening: Bool
    public var endpoints: [PhoneEndpoint]
    /// The name phones reach this Mac by, when Tailscale has one.
    public var host: String?
    /// Why it is not listening, or what it ignored.
    public var problem: String?
    public var phones: [PhoneInfo]
    /// Whether phones get push notifications, and if not, why.
    public var notifications: String

    public init(
        listening: Bool, endpoints: [PhoneEndpoint], host: String?, problem: String?, phones: [PhoneInfo],
        notifications: String
    ) {
        self.listening = listening
        self.endpoints = endpoints
        self.host = host
        self.problem = problem
        self.phones = phones
        self.notifications = notifications
    }
}
