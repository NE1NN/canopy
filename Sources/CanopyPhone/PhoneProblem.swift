import CanopyWire
import Foundation

/// Something that went wrong, as the app says it: what happened, then what to do about it.
public struct PhoneProblem: Error, Equatable, Sendable {
    public var title: String
    public var detail: String
    /// The server's error code, when it refused.
    public var code: String?

    public init(title: String, detail: String = "", code: String? = nil) {
        self.title = title
        self.detail = detail
        self.code = code
    }

    /// `server` names the server in what the app says, by its name or the host the phone tried. `pairCommand` is what
    /// pairs it again, run on the Mac.
    public init(_ error: any Error, server: String, pairCommand: String = "canopy phone pair") {
        switch error {
        case let problem as PhoneProblem:
            self = problem
        case let error as ControlError:
            self = Self.refused(error, server: server, pairCommand: pairCommand)
        case PhoneTransportError.refused:
            self.init(
                title: "Canopy isn't listening on \(server).",
                detail: "Check that Canopy is open on it. canopy phone status on the Mac says why it isn't listening.")
        case PhoneTransportError.closed:
            self.init(title: "Lost the connection to \(server).", detail: Self.checkTailscale)
        case is CancellationError:
            self.init(title: "Stopped.")
        default:
            self.init(title: "Can't reach \(server).", detail: Self.checkTailscale)
        }
    }

    static let checkTailscale =
        "Check that Tailscale is on, on this iPhone and the server, and that the server is awake with Canopy running."

    private static func refused(_ error: ControlError, server: String, pairCommand: String) -> PhoneProblem {
        let title: String
        switch error.code {
        case "bad_pairing_code":
            return PhoneProblem(
                title: "That code expired or was already used.",
                detail: "Run \(pairCommand) on the Mac for a new one.", code: error.code)
        case "unpaired":
            return PhoneProblem(
                title: "\(server) no longer knows this iPhone. Pair it again.",
                detail: "Run \(pairCommand) on the Mac.", code: error.code)
        case "prompt_gone": title = "That prompt moved on before your answer reached it."
        case "prompt_open": title = "Answer the open prompt first. A reply would answer it instead."
        case "agent_not_running": title = "Claude Code isn't running in this pane, so a reply would reach the shell."
        case "no_transcript": title = "This pane has no conversation to show."
        case "pane_not_found": title = "This pane closed."
        case "setup_failed":
            return PhoneProblem(
                title: "The row is made, and its setup failed, so the agent did not start.",
                detail: "Its Setup tab on \(server) shows why.", code: error.code)
        case "too_many_streams": title = "Too many conversations are open. Close one and try again."
        default: title = error.message
        }
        return PhoneProblem(title: title, code: error.code)
    }
}
