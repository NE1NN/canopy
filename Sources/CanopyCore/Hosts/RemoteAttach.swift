import Foundation

public enum HostAttachMethod {
    /// What a remote pane's attach command asks for: the ssh to run, or what to show while the host comes up.
    public static let attach = "host.attach"
    /// What the attach command does once ssh ends.
    public static let next = "host.next"
}

public struct HostAttachParams: Codable, Sendable {
    public var pane: String

    public init(pane: String) {
        self.pane = pane
    }
}

/// One of: the ssh command line to run, a message to show while the host comes up, or why it could not.
public struct HostAttachResult: Codable, Sendable, Equatable {
    public var ready: [String]?
    public var waiting: String?
    public var failed: String?

    public init(ready: [String]? = nil, waiting: String? = nil, failed: String? = nil) {
        self.ready = ready
        self.waiting = waiting
        self.failed = failed
    }
}

public struct HostNextParams: Codable, Sendable {
    public var pane: String
    public var status: Int32

    public init(pane: String, status: Int32) {
        self.pane = pane
        self.status = status
    }
}

public struct HostNextResult: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable {
        /// The session ended, so the pane does.
        case end
        case reconnect
        case waitForReturn
    }

    public var action: Action
    public var message: String?

    public init(action: Action, message: String? = nil) {
        self.action = action
        self.message = message
    }
}

public enum RemoteAttach {
    /// Starts the pane's session on the host, or joins it when it runs already, with Canopy's tmux server and config.
    /// The variables only apply to a session it starts.
    public static func tmuxCommand(server: String, session: String, folder: String, environment: [String: String])
        -> [String]
    {
        let script =
            #"s=$0 n=$1 d=$2; shift 2; exec tmux -u -L "$s" -f "$HOME/.canopy/tmux.conf" new-session -A -s "$n" -c "$d" "$@""#
        let variables = environment.sorted { $0.key < $1.key }.flatMap { ["-e", "\($0.key)=\($0.value)"] }
        return ["sh", "-c", script, server, session, folder] + variables
    }

    /// What a remote pane's shell gets, as a local pane would, with the host's paths. No CANOPY_HOME or ZDOTDIR: those
    /// name folders on this Mac.
    public static func environment(
        pane: String, rowName: String, repoName: String, host: String, rowPath: String, clone: String
    ) -> [String: String] {
        [
            "CANOPY_PANE": pane, "CANOPY_ROW": rowName, "CANOPY_REPO": repoName, "CANOPY_HOST": host,
            "CANOPY_ROW_PATH": rowPath, "CANOPY_ROOT_PATH": clone, "TERM_PROGRAM": "Canopy",
            "TERM_PROGRAM_VERSION": CanopyVersion.current, "COLORTERM": "truecolor",
        ]
    }

    /// ssh exits 255 for its own failures. The session ending ends ssh with 0. While the master still answers, a 255
    /// means the host refused the session rather than went away, and asking again would only be refused again.
    public static func next(status: Int32, state: HostState, host: String, masterAnswers: Bool = false)
        -> HostNextResult
    {
        if status == 0 { return HostNextResult(action: .end) }
        if state == .detached {
            return HostNextResult(
                action: .waitForReturn, message: "Detached so \(host) can sleep. Press Return to reconnect.")
        }
        if status == 255, state == .connected, masterAnswers {
            return HostNextResult(
                action: .waitForReturn,
                message:
                    "\(host) refused another session. Its sshd allows a few per connection (MaxSessions, 10 unless set), "
                    + "and each pane holds one. Close a pane there, or raise MaxSessions on the host. "
                    + "Press Return to try again.")
        }
        if status == 255 { return HostNextResult(action: .reconnect, message: "Lost \(host), reconnecting…") }
        return HostNextResult(
            action: .waitForReturn, message: "tmux on \(host) exited with \(status). Press Return to try again.")
    }

    /// What a pane shows while its host comes up.
    public static func waitingMessage(_ state: HostState, host: String) -> String {
        state == .waking ? "Starting \(host)…" : "Connecting to \(host)…"
    }
}

/// What `canopy remote-attach` does in a remote pane: asks the app for ssh, runs it into the host's tmux session, and
/// asks again when it ends, until the session does.
public struct RemoteAttachLoop: Sendable {
    public var attach: @Sendable () async throws -> HostAttachResult
    public var next: @Sendable (Int32) async throws -> HostNextResult
    public var runSSH: @Sendable ([String]) async -> Int32
    public var print: @Sendable (String) -> Void
    /// A line from the terminal, which arrives once Return is pressed, or nil at the end of input.
    public var readLine: @Sendable () async -> String?
    public var pause: @Sendable (Duration) async -> Void

    public init(
        attach: @escaping @Sendable () async throws -> HostAttachResult,
        next: @escaping @Sendable (Int32) async throws -> HostNextResult,
        runSSH: @escaping @Sendable ([String]) async -> Int32, print: @escaping @Sendable (String) -> Void,
        readLine: @escaping @Sendable () async -> String?, pause: @escaping @Sendable (Duration) async -> Void
    ) {
        self.attach = attach
        self.next = next
        self.runSSH = runSSH
        self.print = print
        self.readLine = readLine
        self.pause = pause
    }

    /// Returns the exit code: 0 once the session ends, 1 when input ends while it waits.
    public func run() async -> Int32 {
        while true {
            guard let argv = await ready() else { return 1 }
            let status = await runSSH(argv)
            let result: HostNextResult
            do {
                result = try await next(status)
            } catch {
                print("\(error)")
                result = HostNextResult(action: .waitForReturn, message: "Press Return to try again.")
            }
            switch result.action {
            case .end:
                return 0
            case .reconnect:
                if let message = result.message { print(message) }
                await pause(.seconds(1))
            case .waitForReturn:
                if let message = result.message { print(message) }
                guard await readLine() != nil else { return 0 }
            }
        }
    }

    /// How long the loop waits, a second at a time, for an app that is not answering, as while it starts.
    static let appPatience = 30

    /// The ssh command line, once the app has one. Nil when input ends while waiting for Return.
    private func ready() async -> [String]? {
        var shown: String?
        var refusals = 0
        while true {
            let result: HostAttachResult
            do {
                result = try await attach()
                refusals = 0
            } catch {
                refusals += 1
                if refusals == 1 { print("Waiting for Canopy…") }
                if refusals <= Self.appPatience {
                    await pause(.seconds(1))
                    continue
                }
                print("\(error)")
                print("Press Return to try again.")
                refusals = 0
                guard await readLine() != nil else { return nil }
                continue
            }
            if let argv = result.ready { return argv }
            if let failed = result.failed {
                print(failed)
                print("Press Return to try again.")
                shown = nil
                guard await readLine() != nil else { return nil }
            } else if let waiting = result.waiting, waiting != shown {
                print(waiting)
                shown = waiting
            }
        }
    }
}
