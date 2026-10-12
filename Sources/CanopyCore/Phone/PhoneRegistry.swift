import CryptoKit
import Foundation

/// A phone paired with this Mac. Only a hash of its token is kept.
public struct PairedPhone: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    /// The token's SHA-256, in hex.
    public var tokenHash: String
    /// Where Apple's push service reaches the phone, once it registers.
    public var pushToken: String?
    public var pairedAt: Date
    public var lastConnected: Date?
}

/// A one-time pairing code.
public struct PairingCode: Sendable, Equatable {
    /// Two groups of four, such as `K7QX-M2PD`.
    public var code: String
    public var expires: Date
}

/// Paired phones, kept in `CANOPY_HOME/phones.json`, and the pairing codes that add them, kept in memory only.
public actor PhoneRegistry {
    public static let codeLifetime: TimeInterval = 5 * 60
    /// Wrong codes in a row after which every outstanding code stops working, so none can be guessed.
    static let wrongCodeLimit = 5
    /// No 0, 1, I, L, O, or U, so a code read aloud or typed cannot be misread.
    static let codeAlphabet = Array("23456789ABCDEFGHJKMNPQRSTVWXYZ")

    public static let badCode = ControlError(
        code: "bad_pairing_code",
        message: "That pairing code is wrong, expired, or already used. Run canopy phone pair on the Mac for a new one."
    )

    public static func notFound(_ name: String) -> ControlError {
        ControlError(
            code: "phone_not_found", message: "No paired phone is named \(name). canopy phone list shows them.")
    }

    private let file: URL
    private let now: @Sendable () -> Date
    private var stored: [PairedPhone]
    private var codes: [String: Date] = [:]
    /// Which phone each used code paired, for `waitForPairing`.
    private var redeemed: [String: String] = [:]
    private var wrongCodes = 0

    public init(file: URL, now: @escaping @Sendable () -> Date = Date.init) {
        self.file = file
        self.now = now
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        stored = (try? decoder.decode([PairedPhone].self, from: Data(contentsOf: file))) ?? []
    }

    public var phones: [PairedPhone] { stored }

    public func newCode() -> PairingCode {
        var generator = SystemRandomNumberGenerator()
        let letters = (0..<8).map { _ in Self.codeAlphabet.randomElement(using: &generator) ?? "A" }
        let code = String(letters[0..<4]) + "-" + String(letters[4...])
        let expires = now() + Self.codeLifetime
        codes[Self.normalized(code)] = expires
        return PairingCode(code: code, expires: expires)
    }

    /// Trades a code for a new phone and its token. The token is returned this once and never kept.
    public func redeem(code: String, name: String) throws -> (phone: PairedPhone, token: String) {
        let key = Self.normalized(code)
        let current = now()
        codes = codes.filter { $0.value > current }
        guard codes.removeValue(forKey: key) != nil else {
            wrongCodes += 1
            if wrongCodes >= Self.wrongCodeLimit {
                codes = [:]
                wrongCodes = 0
            }
            throw Self.badCode
        }
        wrongCodes = 0
        var bytes = [UInt8](repeating: 0, count: 32)
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices { bytes[index] = generator.next() }
        let token = Data(bytes).base64URLEncodedString()
        let phone = PairedPhone(
            id: UUID().uuidString, name: uniqueName(name), tokenHash: Self.hash(token), pushToken: nil,
            pairedAt: current, lastConnected: nil)
        stored.append(phone)
        do {
            try save()
        } catch {
            stored.removeLast()
            throw ControlError(code: "internal", message: "Could not save the paired phone: \(error)")
        }
        redeemed[key] = phone.id
        return (phone, token)
    }

    /// The phone the token belongs to. Every stored hash is compared in full, so the time taken says nothing.
    public func authenticate(token: String) -> PairedPhone? {
        let presented = Array(Self.hash(token).utf8)
        var found: PairedPhone?
        for phone in stored where Self.constantTimeEqual(Array(phone.tokenHash.utf8), presented) {
            found = phone
        }
        return found
    }

    public func remove(name: String) throws -> PairedPhone {
        guard let index = stored.firstIndex(where: { $0.name == name }) else { throw Self.notFound(name) }
        let phone = stored.remove(at: index)
        try save()
        return phone
    }

    public func connected(_ id: String) {
        guard let index = stored.firstIndex(where: { $0.id == id }) else { return }
        stored[index].lastConnected = now()
        try? save()
    }

    /// The phone that pairs with `code`, or nil once the code expires unused.
    public func waitForPairing(code: String, polling: Duration = .milliseconds(200)) async -> PairedPhone? {
        let key = Self.normalized(code)
        while !Task.isCancelled {
            if let id = redeemed[key] { return stored.first { $0.id == id } }
            guard let expires = codes[key], expires > now() else { return nil }
            try? await Task.sleep(for: polling)
        }
        return nil
    }

    static func normalized(_ code: String) -> String {
        code.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices { difference |= lhs[index] ^ rhs[index] }
        return difference == 0
    }

    private func uniqueName(_ requested: String) -> String {
        let trimmed = String(requested.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        let base = trimmed.isEmpty ? "iPhone" : trimmed
        let taken = Set(stored.map(\.name))
        guard taken.contains(base) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }

    /// Written beside the file and renamed over it, readable only by the author.
    private func save() throws {
        let manager = FileManager.default
        let folder = file.deletingLastPathComponent()
        let temporary = folder.appending(path: ".\(file.lastPathComponent).\(UUID().uuidString.prefix(8))")
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(stored).write(to: temporary)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            guard rename(temporary.path, file.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded text: String) {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
