import CanopyWire
import Foundation
import Observation

/// The Pairing screen: a link from the camera, a paste, or a `canopy-phone://` URL, traded for a token.
@MainActor @Observable
public final class PairingModel {
    public let servers: Servers
    public private(set) var isPairing = false
    public private(set) var problem: PhoneProblem?
    /// The server the last pairing added or paired again.
    public private(set) var lastPaired: ServerConnection?
    /// Counts pairings that worked, so a sheet that paired a server, even one paired before, can close.
    public private(set) var pairings = 0
    /// The last link tried, which the camera keeps seeing while it points at the code: one that failed waits for a new
    /// code, and one that worked is spent.
    private var tried: URL?

    public init(servers: Servers) {
        self.servers = servers
    }

    /// Why the phone is here again, when the last server that knew it forgot it.
    public var notice: String? { servers.pairingNotice }

    public func dismissProblem() {
        problem = nil
    }

    /// A fresh start, as when the screen opens again: no problem from before, and a code seen before may be tried.
    public func reset() {
        problem = nil
        tried = nil
    }

    public func pair(text: String) async {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), PairingLink(url: url) != nil
        else {
            problem = PhoneProblem(
                title: "That isn't a Canopy pairing link.",
                detail: "Run canopy phone pair on the Mac, and copy the link it prints.")
            return
        }
        await pair(url)
    }

    /// `scanned` is for the camera, which sees the code many times a second: a link just tried, which failed or is
    /// spent, waits for a new code, rather than trying again with each frame.
    public func pair(_ url: URL, scanned: Bool = false) async {
        guard let link = PairingLink(url: url) else {
            await pair(text: url.absoluteString)
            return
        }
        guard !isPairing, !(scanned && url == tried) else { return }
        isPairing = true
        problem = nil
        defer { isPairing = false }
        tried = url
        do {
            lastPaired = try await servers.pair(link)
            pairings += 1
        } catch {
            problem = PhoneProblem(error, server: link.host)
        }
    }
}
