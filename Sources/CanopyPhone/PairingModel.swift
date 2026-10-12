import CanopyWire
import Foundation
import Observation

/// The Pairing screen: a link from the camera, a paste, or a `canopy-phone://` URL, traded for a token.
@MainActor @Observable
public final class PairingModel {
    public let connection: MacConnection
    public private(set) var isPairing = false
    public private(set) var problem: PhoneProblem?
    /// The last link that failed, which the camera keeps seeing while it points at the code.
    private var failed: URL?

    public init(connection: MacConnection) {
        self.connection = connection
    }

    /// Why the phone is here again, when the Mac forgot it.
    public var notice: String? { connection.pairingNotice }

    public func dismissProblem() {
        problem = nil
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

    /// `scanned` is for the camera, which sees the code many times a second: a link that just failed waits for a new
    /// code, rather than trying again with each frame.
    public func pair(_ url: URL, scanned: Bool = false) async {
        guard let link = PairingLink(url: url) else {
            await pair(text: url.absoluteString)
            return
        }
        guard !isPairing, !(scanned && url == failed) else { return }
        isPairing = true
        problem = nil
        defer { isPairing = false }
        do {
            try await connection.pair(link)
            failed = nil
        } catch {
            failed = url
            problem = PhoneProblem(error, mac: link.host)
        }
    }
}
