import CanopyWire
import Foundation
import Observation

/// The Pairing screen: a link from the camera, a paste, or a `canopy-phone://` URL, traded for a token.
@MainActor @Observable
public final class PairingModel {
    public let connection: MacConnection
    public private(set) var isPairing = false
    public private(set) var problem: PhoneProblem?

    public init(connection: MacConnection) {
        self.connection = connection
    }

    /// Why the phone is here again, when the Mac forgot it.
    public var notice: String? { connection.pairingNotice }

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

    public func pair(_ url: URL) async {
        guard let link = PairingLink(url: url) else {
            await pair(text: url.absoluteString)
            return
        }
        // The camera sees the code many times a second.
        guard !isPairing else { return }
        isPairing = true
        problem = nil
        defer { isPairing = false }
        do {
            try await connection.pair(link)
        } catch {
            problem = PhoneProblem(error, mac: link.host)
        }
    }
}
