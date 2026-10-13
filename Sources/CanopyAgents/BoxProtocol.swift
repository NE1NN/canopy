import CanopyWire
import Foundation

/// What the Mac asks canopy-box on a host, through the host's `box.sock` forwarded over ssh. Newline-delimited JSON,
/// as the control socket speaks, with `box.snapshot` events for a subscription.
public enum BoxMethod {
    /// Both sides' versions. Params: `BoxHelloParams`. Result: `BoxHelloResult`.
    public static let hello = "box.hello"
    /// Sets what the Mac decides for the box. Params: `BoxConfig`.
    public static let configure = "box.configure"
    /// A `box.snapshot` event at once and on each change. Result: true.
    public static let subscribe = "box.subscribe"
    /// Params: `BoxRowNewParams`. Result: `BoxRowNewResult`.
    public static let rowNew = "box.rowNew"
    /// Params: `BoxRowRemoveParams`. Result: `BoxRowRemoveResult`.
    public static let rowRemove = "box.rowRemove"
    /// Params: `BoxPaneNewParams`. Result: `BoxPaneNewResult`.
    public static let paneNew = "box.paneNew"
    /// Params: `BoxPaneParams`.
    public static let paneClose = "box.paneClose"
    /// Params: `TermSendParams`.
    public static let send = "box.send"
    /// Params: `BoxKeysParams`.
    public static let keys = "box.keys"
    /// Keys typed into a pane elsewhere, as through the Mac's tmux attach, for the agent's key rules alone: they do
    /// not go into the pane. Params: `BoxKeysParams`.
    public static let typed = "box.typed"
    /// Params: `TermReadParams`. Result: `TermReadResult`.
    public static let read = "box.read"
    /// Params: `TermWaitParams`. Result: `TermWaitResult`.
    public static let wait = "box.wait"
    /// Params: `BoxPaneParams`.
    public static let seen = "box.seen"
    /// Params: `BoxPRsParams`.
    public static let prs = "box.prs"
    /// Params: `BoxAdoptParams`. Result: `BoxAdoptResult`.
    public static let adopt = "box.adopt"
    /// Result: `BoxReleaseResult`.
    public static let release = "box.release"
    /// The box's own phones, as `phones.pair`, `phones.paired`, `phones.list`, `phones.remove`, and `phones.status`
    /// are on the Mac, with the same params and results.
    public static let phonesPair = "box.phones.pair"
    public static let phonesPaired = "box.phones.paired"
    public static let phonesList = "box.phones.list"
    public static let phonesRemove = "box.phones.remove"
    public static let phonesStatus = "box.phones.status"
}

public enum BoxProtocol {
    /// Goes up only when a method changes in a way an older side would misread. New fields are ignored by older sides.
    public static let version = 1
}

public struct BoxHelloParams: Codable, Sendable, Equatable {
    /// The Mac app's version.
    public var version: String

    public init(version: String) {
        self.version = version
    }
}

public struct BoxHelloResult: Codable, Sendable, Equatable {
    /// canopy-box's version.
    public var version: String
    public var protocolVersion: Int
    public var homeID: String
    /// Whether the Mac has sent `box.configure` since this home's files were made.
    public var configured: Bool

    public init(version: String, protocolVersion: Int, homeID: String, configured: Bool) {
        self.version = version
        self.protocolVersion = protocolVersion
        self.homeID = homeID
        self.configured = configured
    }
}

/// What the Mac decides for the box, kept in its `config.json`.
public struct BoxConfig: Codable, Sendable, Equatable {
    /// The host as the Mac's `~/.ssh/config` names it, which panes get as CANOPY_HOST.
    public var host: String
    /// Registered repos' names, each to its clone's absolute path on the host.
    public var repos: [String: String]
    /// What a task from the phone runs. Nil for the default.
    public var agentCommand: String?
    /// The port phones connect to. Nil for the standard one.
    public var phonePort: UInt16?
    /// The key phones start the box's instance with. Nil when none is set.
    public var wake: BoxWakeKey?
    /// The Mac could not read its key, so the box keeps the one it has rather than forgetting it.
    public var keepsWake: Bool?

    public init(
        host: String, repos: [String: String] = [:], agentCommand: String? = nil, phonePort: UInt16? = nil,
        wake: BoxWakeKey? = nil, keepsWake: Bool? = nil
    ) {
        self.host = host
        self.repos = repos
        self.agentCommand = agentCommand
        self.phonePort = phonePort
        self.wake = wake
        self.keepsWake = keepsWake
    }
}

/// An AWS access key whose only permission is `ec2:StartInstances` on the box's instance, which a phone signs with to
/// start a box that powered itself off.
public struct BoxWakeKey: Codable, Sendable, Equatable {
    public var accessKeyID: String
    public var secretAccessKey: String

    public init(accessKeyID: String, secretAccessKey: String) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
    }
}

/// A row on the box: a repo's clone, which is its main row there, or a worktree under `~/.canopy/worktrees/<repo>/`.
public struct BoxRow: Codable, Sendable, Equatable {
    public var path: String
    public var repo: String
    public var branch: String?
    public var head: String?
    public var isMain: Bool
    /// The worktree is gone from git's list.
    public var missing: Bool
    /// The last pull request number the Mac reported for its branch.
    public var pr: Int?

    public init(
        path: String, repo: String, branch: String? = nil, head: String? = nil, isMain: Bool = false,
        missing: Bool = false, pr: Int? = nil
    ) {
        self.path = path
        self.repo = repo
        self.branch = branch
        self.head = head
        self.isMain = isMain
        self.missing = missing
        self.pr = pr
    }
}

/// A pane on the box: a tmux session of the home's server, which the Mac attaches a terminal to.
public struct BoxPane: Codable, Sendable, Equatable {
    /// The session's name: `b<N>` for panes the box made, `p<N>` for panes the Mac made before the host upgraded.
    public var id: String
    public var rowPath: String
    public var folder: String
    /// The program in the foreground, such as `claude`, or the shell.
    public var foreground: String?
    public var title: String?
    /// A program other than the shell holds the terminal.
    public var busy: Bool
    public var agent: AgentState
    /// Done and not yet seen.
    public var unseen: Bool
    public var backgroundTasks: [String]
    public var transcriptPath: String?
    public var prompt: OpenPrompt?
    /// When the agent reached its state, in seconds since 1970.
    public var since: Double
    /// The screen's last line that is not blank.
    public var lastLine: String?

    public init(
        id: String, rowPath: String, folder: String, foreground: String? = nil, title: String? = nil,
        busy: Bool = false, agent: AgentState = .none, unseen: Bool = false, backgroundTasks: [String] = [],
        transcriptPath: String? = nil, prompt: OpenPrompt? = nil, since: Double = 0, lastLine: String? = nil
    ) {
        self.id = id
        self.rowPath = rowPath
        self.folder = folder
        self.foreground = foreground
        self.title = title
        self.busy = busy
        self.agent = agent
        self.unseen = unseen
        self.backgroundTasks = backgroundTasks
        self.transcriptPath = transcriptPath
        self.prompt = prompt
        self.since = since
        self.lastLine = lastLine
    }
}

/// Everything the box has, sent whole on each change.
public struct BoxSnapshot: Codable, Sendable, Equatable {
    public var rows: [BoxRow]
    public var panes: [BoxPane]

    public init(rows: [BoxRow] = [], panes: [BoxPane] = []) {
        self.rows = rows
        self.panes = panes
    }
}

public struct BoxRowNewParams: Codable, Sendable, Equatable {
    public var repo: String
    public var branch: String
    /// Start point for a new branch.
    public var base: String?
    /// Fail rather than make a branch that is neither local nor on origin.
    public var existing: Bool

    public init(repo: String, branch: String, base: String? = nil, existing: Bool = false) {
        self.repo = repo
        self.branch = branch
        self.base = base
        self.existing = existing
    }
}

public struct BoxRowNewResult: Codable, Sendable, Equatable {
    public var row: BoxRow
    public var source: BranchSource
    public var base: String?
    public var notes: [String]
    public var warnings: [String]

    public init(row: BoxRow, source: BranchSource, base: String?, notes: [String], warnings: [String]) {
        self.row = row
        self.source = source
        self.base = base
        self.notes = notes
        self.warnings = warnings
    }
}

public struct BoxRowRemoveParams: Codable, Sendable, Equatable {
    public var path: String
    public var force: Bool
    public var deleteBranch: Bool

    public init(path: String, force: Bool = false, deleteBranch: Bool = false) {
        self.path = path
        self.force = force
        self.deleteBranch = deleteBranch
    }
}

public struct BoxRowRemoveResult: Codable, Sendable, Equatable {
    public var warnings: [String]

    public init(warnings: [String]) {
        self.warnings = warnings
    }
}

public struct BoxPaneNewParams: Codable, Sendable, Equatable {
    public var rowPath: String
    /// Typed into the pane once its shell is up.
    public var command: String?
    /// Variables the pane's shell gets beside Canopy's own, such as a task's brief, which is never typed.
    public var environment: [String: String]?

    public init(rowPath: String, command: String? = nil, environment: [String: String]? = nil) {
        self.rowPath = rowPath
        self.command = command
        self.environment = environment
    }
}

public struct BoxPaneNewResult: Codable, Sendable, Equatable {
    public var pane: String

    public init(pane: String) {
        self.pane = pane
    }
}

public struct BoxPaneParams: Codable, Sendable, Equatable {
    public var pane: String

    public init(pane: String) {
        self.pane = pane
    }
}

public struct BoxKeysParams: Codable, Sendable, Equatable {
    public var pane: String
    /// Each goes in as the bytes a terminal sends, one at a time.
    public var keys: [String]

    public init(pane: String, keys: [String]) {
        self.pane = pane
        self.keys = keys
    }
}

public struct BoxPRsParams: Codable, Sendable, Equatable {
    /// Pull request numbers by row path. A row left out has none.
    public var prs: [String: Int]

    public init(prs: [String: Int]) {
        self.prs = prs
    }
}

/// A row the Mac hands the box as the host upgrades.
public struct BoxAdoptedRow: Codable, Sendable, Equatable {
    public var repo: String
    public var path: String
    public var branch: String?

    public init(repo: String, path: String, branch: String?) {
        self.repo = repo
        self.path = path
        self.branch = branch
    }
}

/// A pane the Mac hands the box as the host upgrades: its session's name, its row, and its agent.
public struct BoxAdoptedPane: Codable, Sendable, Equatable {
    public var id: String
    public var rowPath: String
    public var folder: String
    public var agent: PaneAgent

    public init(id: String, rowPath: String, folder: String, agent: PaneAgent) {
        self.id = id
        self.rowPath = rowPath
        self.folder = folder
        self.agent = agent
    }
}

public struct BoxAdoptParams: Codable, Sendable, Equatable {
    public var rows: [BoxAdoptedRow]
    public var panes: [BoxAdoptedPane]
    /// The Mac's next pane number, so the box never makes a `b<N>` beside a `p<N>` of the same number.
    public var nextPane: Int

    public init(rows: [BoxAdoptedRow], panes: [BoxAdoptedPane], nextPane: Int) {
        self.rows = rows
        self.panes = panes
        self.nextPane = nextPane
    }
}

public struct BoxAdoptResult: Codable, Sendable, Equatable {
    /// The rows and panes the box took.
    public var rows: [String]
    public var panes: [String]
    /// Panes whose session the host's tmux server does not have.
    public var missing: [String]

    public init(rows: [String], panes: [String], missing: [String]) {
        self.rows = rows
        self.panes = panes
        self.missing = missing
    }
}

/// Everything the box had, for the Mac to take back as the host goes back to how it was.
public struct BoxReleaseResult: Codable, Sendable, Equatable {
    public var rows: [BoxAdoptedRow]
    public var panes: [BoxAdoptedPane]
    public var nextPane: Int

    public init(rows: [BoxAdoptedRow], panes: [BoxAdoptedPane], nextPane: Int) {
        self.rows = rows
        self.panes = panes
        self.nextPane = nextPane
    }
}

/// Something canopy-box sends without being asked, for a subscription.
public struct BoxEvent: Codable, Sendable, Equatable {
    /// The box changed. `data` is the new `BoxSnapshot`.
    public static let snapshot = "box.snapshot"

    public var v: Int
    public var event: String
    /// The ID of the request that started the subscription.
    public var subscription: String
    public var data: JSONValue

    public init(event: String, subscription: String, data: JSONValue, v: Int = ControlCodec.version) {
        self.v = v
        self.event = event
        self.subscription = subscription
        self.data = data
    }
}

/// One line from canopy-box: the answer to a request, or an event.
public enum BoxMessage: Sendable, Equatable {
    case response(ControlResponse)
    case event(BoxEvent)

    public init(line: Data) throws {
        let decoder = JSONDecoder()
        let keys = try decoder.decode([String: JSONValue].self, from: line)
        if keys["event"] != nil {
            self = .event(try decoder.decode(BoxEvent.self, from: line))
        } else {
            self = .response(try decoder.decode(ControlResponse.self, from: line))
        }
    }
}
