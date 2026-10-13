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
    /// Makes a row and opens a pane in it running the server's agent command with a brief.
    public static let newRow = "phone.newRow"
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
    /// After a reset, the cursor for the new conversation's next older page.
    public var older: Int?

    public init(pane: String, entries: [TranscriptEntry], reset: Bool = false, older: Int? = nil) {
        self.pane = pane
        self.entries = entries
        self.reset = reset
        self.older = older
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

/// A task for the server's agent: a row made by `row new`'s branch rules, and the brief its agent starts with.
public struct PhoneNewRowParams: Codable, Sendable, Equatable {
    /// The repo's name, as the server's rows name it.
    public var repo: String
    public var branch: String
    /// Where a new branch starts. Nil for a branch that exists, or else origin's default branch.
    public var base: String?
    public var brief: String

    public init(repo: String, branch: String, base: String? = nil, brief: String) {
        self.repo = repo
        self.branch = branch
        self.base = base
        self.brief = brief
    }
}

public struct PhoneNewRowResult: Codable, Sendable, Equatable {
    /// The row's folder on the server.
    public var path: String
    /// Its branch, which can differ from the one asked for, as when the server picked a free name.
    public var branch: String
    /// The pane the agent runs in.
    public var pane: String
    /// What the server said about making it, such as a failed fetch.
    public var warnings: [String]?

    public init(path: String, branch: String, pane: String, warnings: [String]? = nil) {
        self.path = path
        self.branch = branch
        self.pane = pane
        self.warnings = warnings
    }
}

/// What a task from the phone runs: the server's agent command, which the Mac sets and the phone cannot change.
public enum PhoneAgentCommand {
    public static let standard = "claude --model 'opus[1m]' --permission-mode bypassPermissions"

    /// The command a server set, or the standard one when it set none or only blanks.
    public static func chosen(_ command: String?) -> String {
        guard let command = command?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else {
            return standard
        }
        return command
    }

    /// The variable the new pane's shell gets the brief in. The brief is never typed: a shell's line editor reads
    /// control characters in typed text as keys, even inside quotes, so typing it could run anything.
    public static let briefVariable = "CANOPY_TASK_BRIEF"
    /// The longest brief, in UTF-8 bytes, well under Linux's 128 KiB for one environment entry.
    public static let briefLimit = 32 * 1024

    /// What the pane types: the command, and the brief from `briefVariable` as one argument. An empty brief adds
    /// nothing.
    public static func line(_ command: String, brief: String) -> String {
        brief.isEmpty ? command : command + " \"$\(briefVariable)\""
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

/// What a server is: a Mac, or canopy-box on a host. One that does not say is a Mac.
public enum PhoneServerKind {
    public static let mac = "mac"
    public static let box = "box"
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
    /// `PhoneServerKind`'s; nil from a Mac older than several servers.
    public var kind: String?
    /// How the phone starts a box that powered itself off. Only a box with a wake key sends it.
    public var wake: PhoneWake?
    /// What a task from the phone runs. Nil from a server older than New task.
    public var agentCommand: String?

    public init(
        mac: String, version: String, phone: String, kind: String? = nil, wake: PhoneWake? = nil,
        agentCommand: String? = nil
    ) {
        self.mac = mac
        self.version = version
        self.phone = phone
        self.kind = kind
        self.wake = wake
        self.agentCommand = agentCommand
    }
}

/// What a phone needs to start a box's EC2 instance itself: a key whose only permission is to start it, and which
/// instance it is.
public struct PhoneWake: Codable, Sendable, Equatable {
    public var accessKeyID: String
    public var secretAccessKey: String
    public var instanceID: String
    public var region: String

    public init(accessKeyID: String, secretAccessKey: String, instanceID: String, region: String) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.instanceID = instanceID
        self.region = region
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
    /// `PhoneServerKind`'s; nil from a Mac older than several servers.
    public var kind: String?

    public init(token: String, phone: String, mac: String, kind: String? = nil) {
        self.token = token
        self.phone = phone
        self.mac = mac
        self.kind = kind
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
