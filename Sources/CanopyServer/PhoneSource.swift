import CanopyWire
import Foundation

/// Where a phone server finds rows and panes: the Mac's terminals, or canopy-box's tmux sessions. Errors it throws are
/// `ControlError`s with the codes the phone reads, such as `pane_not_found`, `prompt_gone`, and `agent_not_running`.
public protocol PhoneSource: Sendable {
    /// Every row with its agents, as the inbox shows them.
    func inbox() async -> PhoneInbox
    /// Every row by repo and plugin, with PRs.
    func rows() async -> PhoneRowsResult
    /// Sends the inbox whenever it changes from what was last sent. A subscription it replaces stops.
    func subscribe(
        after lastSent: PhoneInbox, replacing previous: UUID?, _ send: @escaping @Sendable (PhoneInbox) -> Void
    )
        async -> UUID
    func unsubscribe(_ id: UUID) async
    /// The pane's conversation, or `no_transcript`.
    func transcriptURL(_ pane: String) async throws -> URL
    /// Pastes a reply into the pane and presses Return; `delivered` runs once the agent takes it.
    func reply(_ params: PhoneReplyParams, delivered: @escaping @Sendable () -> Void) async throws
    func answer(_ params: PhoneAnswerParams) async throws
    func keys(_ params: PhoneKeysParams) async throws
    func seen(_ params: PhonePaneParams) async throws
    /// The pane's visible screen, with up to `scrollback` lines above it.
    func screen(_ params: PhonePaneParams, scrollback: Int?) async throws -> PhoneScreen
    /// Makes a row by `row new`'s branch rules and opens a pane in it that runs `line`, the agent command with the
    /// brief.
    func newRow(_ params: PhoneNewRowParams, line: String) async throws -> PhoneNewRowResult
}

/// What a phone server records in its activity log.
public enum PhoneActivity: Sendable, Equatable {
    case paired(phone: String)
    case removed(phone: String)
    /// A call that changed something, with the phone's name, the method, the pane, and what it sent.
    case call([String: JSONValue])
}

/// What a phone server needs from where it runs.
public struct PhoneServerSettings: Sendable {
    public var registryFile: URL
    /// The name phones see, such as the Mac's or the host's, asked at each pairing and hello, since a box learns its
    /// name from the Mac after it starts.
    public var serverName: @Sendable () -> String
    /// `PhoneServerKind`'s, which hello, pairing, and the pairing link say.
    public var kind: String
    /// What hello gives a phone to start the server with, asked each time. Only a box has one.
    public var wake: @Sendable () -> PhoneWake?
    /// What a task from a phone runs, asked each time, as the Mac can change it while the server runs.
    public var agentCommand: @Sendable () -> String
    public var version: String
    public var port: UInt16
    /// The addresses to listen on now.
    public var addresses: @Sendable () -> [String]
    /// The tailnet name pairing links carry, or nil to carry the address.
    public var tailnetName: @Sendable () async -> String?
    /// Why it has no address to listen on, for `canopy phone status` and a refused pairing.
    public var closedReason: @Sendable () -> String
    /// Something status always says, as when an override is ignored.
    public var statusNote: String?
    public var logsCommands: @Sendable () -> Bool
    public var record: @Sendable (PhoneActivity) -> Void

    public init(
        registryFile: URL, serverName: @escaping @Sendable () -> String, kind: String = PhoneServerKind.mac,
        wake: @escaping @Sendable () -> PhoneWake? = { nil },
        agentCommand: @escaping @Sendable () -> String = { PhoneAgentCommand.standard }, version: String, port: UInt16,
        addresses: @escaping @Sendable () -> [String], tailnetName: @escaping @Sendable () async -> String?,
        closedReason: @escaping @Sendable () -> String, statusNote: String? = nil,
        logsCommands: @escaping @Sendable () -> Bool = { false }, record: @escaping @Sendable (PhoneActivity) -> Void
    ) {
        self.registryFile = registryFile
        self.serverName = serverName
        self.kind = kind
        self.wake = wake
        self.agentCommand = agentCommand
        self.version = version
        self.port = port
        self.addresses = addresses
        self.tailnetName = tailnetName
        self.closedReason = closedReason
        self.statusNote = statusNote
        self.logsCommands = logsCommands
        self.record = record
    }
}
