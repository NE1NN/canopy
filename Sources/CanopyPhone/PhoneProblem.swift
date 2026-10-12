import CanopyWire
import Foundation

/// Something that went wrong, as the app says it: what happened, then what to do about it.
public struct PhoneProblem: Error, Equatable, Sendable {
    public var title: String
    public var detail: String
    /// The Mac's error code, when the Mac refused.
    public var code: String?

    public init(title: String, detail: String = "", code: String? = nil) {
        self.title = title
        self.detail = detail
        self.code = code
    }

    /// `mac` names the Mac in what the app says, by its name or the host the phone tried.
    public init(_ error: any Error, mac: String) {
        switch error {
        case let problem as PhoneProblem:
            self = problem
        case let error as ControlError:
            self = Self.refused(error, mac: mac)
        case PhoneTransportError.refused:
            self.init(
                title: "Canopy isn't listening on \(mac).",
                detail: "Open Canopy on the Mac. canopy phone status there says why it isn't listening.")
        case PhoneTransportError.closed:
            self.init(title: "Lost the connection to \(mac).", detail: Self.checkTailscale)
        case is CancellationError:
            self.init(title: "Stopped.")
        default:
            self.init(title: "Can't reach \(mac).", detail: Self.checkTailscale)
        }
    }

    static let checkTailscale =
        "Check that Tailscale is on, on this iPhone and the Mac, and that the Mac is awake with Canopy open."

    private static func refused(_ error: ControlError, mac: String) -> PhoneProblem {
        let title: String
        switch error.code {
        case "bad_pairing_code":
            return PhoneProblem(
                title: "That code expired or was already used.",
                detail: "Run canopy phone pair on the Mac for a new one.", code: error.code)
        case "unpaired":
            return PhoneProblem(
                title: "\(mac) no longer knows this iPhone. Pair it again.",
                detail: "Run canopy phone pair on the Mac.", code: error.code)
        case "prompt_gone": title = "That prompt moved on before your answer reached it."
        case "prompt_open": title = "Answer the open prompt first. A reply would answer it instead."
        case "agent_not_running": title = "Claude Code isn't running in this pane, so a reply would reach the shell."
        case "no_transcript": title = "This pane has no conversation to show."
        case "pane_not_found": title = "This pane closed."
        case "too_many_streams": title = "Too many conversations are open. Close one and try again."
        default: title = error.message
        }
        return PhoneProblem(title: title, code: error.code)
    }
}
