import Foundation

/// Who wrote a message in a ticket's Discord channel.
public struct MessageAuthor: Sendable, Equatable, Codable {
    public enum Role: Sendable, Equatable, Codable {
        case staff, customer
        case other(String)

        public init(from decoder: any Decoder) throws {
            let text = try decoder.singleValueContainer().decode(String.self)
            self = text == "staff" ? .staff : text == "customer" ? .customer : .other(text)
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .staff: try container.encode("staff")
            case .customer: try container.encode("customer")
            case .other(let text): try container.encode(text)
            }
        }
    }

    public var username: String
    public var displayName: String?
    public var avatarUrl: String?
    public var role: Role
    public var isBot: Bool

    public init(username: String, displayName: String?, avatarUrl: String?, role: Role, isBot: Bool) {
        self.username = username
        self.displayName = displayName
        self.avatarUrl = avatarUrl
        self.role = role
        self.isBot = isBot
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        username = try container.decode(String.self, forKey: .username)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        avatarUrl = try container.decodeIfPresent(String.self, forKey: .avatarUrl)
        role = try container.decodeIfPresent(Role.self, forKey: .role) ?? .other("")
        isBot = try container.decodeIfPresent(Bool.self, forKey: .isBot) ?? false
    }

    /// The display name, or the username when there is none.
    public var shownName: String {
        guard let displayName, !displayName.isEmpty else { return username }
        return displayName
    }
}

/// A user a message mentions, so `<@id>` can show their name.
public struct MessageMention: Sendable, Equatable, Codable {
    public var id: String
    public var username: String
    public var displayName: String?

    public init(id: String, username: String, displayName: String?) {
        self.id = id
        self.username = username
        self.displayName = displayName
    }
}

public struct MessageAttachment: Sendable, Equatable, Codable {
    public var filename: String
    public var url: String
    public var size: Int64
    public var contentType: String?

    public init(filename: String, url: String, size: Int64, contentType: String?) {
        self.filename = filename
        self.url = url
        self.size = size
        self.contentType = contentType
    }
}

/// The thread a message was posted in.
public struct MessageThread: Sendable, Equatable, Codable {
    public var id: String
    /// Null for every thread today: ticket-manager does not store thread names yet.
    public var name: String?

    public init(id: String, name: String?) {
        self.id = id
        self.name = name
    }
}

public struct TicketMessage: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    /// Opens the message in Discord.
    public var discordUrl: String?
    public var author: MessageAuthor
    public var text: String
    public var mentions: [MessageMention]
    public var attachments: [MessageAttachment]
    /// Milliseconds since the epoch.
    public var postedAt: Int64
    public var thread: MessageThread?

    public init(
        id: String, discordUrl: String?, author: MessageAuthor, text: String, mentions: [MessageMention],
        attachments: [MessageAttachment], postedAt: Int64, thread: MessageThread?
    ) {
        self.id = id
        self.discordUrl = discordUrl
        self.author = author
        self.text = text
        self.mentions = mentions
        self.attachments = attachments
        self.postedAt = postedAt
        self.thread = thread
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        discordUrl = try container.decodeIfPresent(String.self, forKey: .discordUrl)
        author = try container.decode(MessageAuthor.self, forKey: .author)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        mentions = try container.decodeIfPresent([MessageMention].self, forKey: .mentions) ?? []
        attachments = try container.decodeIfPresent([MessageAttachment].self, forKey: .attachments) ?? []
        postedAt = try container.decode(Int64.self, forKey: .postedAt)
        thread = try container.decodeIfPresent(MessageThread.self, forKey: .thread)
    }

    public var posted: Date { Date(milliseconds: postedAt) }
}

/// Something the customer needs, as ticket-manager's model found it in the conversation.
public struct TicketProblem: Sendable, Equatable, Codable, Identifiable {
    public var key: String
    public var title: String
    public var bullets: [String]
    public var category: String?
    /// "open" or "resolved".
    public var status: String

    public init(key: String, title: String, bullets: [String], category: String?, status: String) {
        self.key = key
        self.title = title
        self.bullets = bullets
        self.category = category
        self.status = status
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        title = try container.decode(String.self, forKey: .title)
        bullets = try container.decodeIfPresent([String].self, forKey: .bullets) ?? []
        category = try container.decodeIfPresent(String.self, forKey: .category)
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "open"
    }

    public var id: String { key }
    public var isOpen: Bool { status != "resolved" }
}

/// ticket-manager's latest suggested reply, whatever its status.
public struct TicketDraft: Sendable, Equatable, Codable {
    public var text: String
    public var status: String
    public var sourcesUsed: [String]
    /// Milliseconds since the epoch.
    public var generatedAt: Int64?
    /// Why generating it failed, if it did.
    public var error: String?

    public init(text: String, status: String, sourcesUsed: [String], generatedAt: Int64?, error: String?) {
        self.text = text
        self.status = status
        self.sourcesUsed = sourcesUsed
        self.generatedAt = generatedAt
        self.error = error
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
        sourcesUsed = try container.decodeIfPresent([String].self, forKey: .sourcesUsed) ?? []
        generatedAt = try container.decodeIfPresent(Int64.self, forKey: .generatedAt)
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }
}

/// A handover note an engineer left on the ticket.
public struct TicketNote: Sendable, Equatable, Codable {
    public var text: String
    public var authorEmail: String?
    /// Milliseconds since the epoch.
    public var createdAt: Int64

    public init(text: String, authorEmail: String?, createdAt: Int64) {
        self.text = text
        self.authorEmail = authorEmail
        self.createdAt = createdAt
    }
}

/// `tickets/<id>`: everything the panel shows about one ticket.
public struct TicketDetail: Sendable, Equatable, Codable {
    public var ticket: TicketSummary
    public var messages: [TicketMessage]
    public var problems: [TicketProblem]
    public var draft: TicketDraft?
    /// The markdown the web app's "Copy handover block" copies.
    public var handover: String
    public var notes: [TicketNote]

    public init(
        ticket: TicketSummary, messages: [TicketMessage], problems: [TicketProblem], draft: TicketDraft?,
        handover: String, notes: [TicketNote]
    ) {
        self.ticket = ticket
        self.messages = messages
        self.problems = problems
        self.draft = draft
        self.handover = handover
        self.notes = notes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ticket = try container.decode(TicketSummary.self, forKey: .ticket)
        messages = try container.decodeIfPresent([TicketMessage].self, forKey: .messages) ?? []
        problems = try container.decodeIfPresent([TicketProblem].self, forKey: .problems) ?? []
        draft = try container.decodeIfPresent(TicketDraft.self, forKey: .draft)
        handover = try container.decodeIfPresent(String.self, forKey: .handover) ?? ""
        notes = try container.decodeIfPresent([TicketNote].self, forKey: .notes) ?? []
    }
}
