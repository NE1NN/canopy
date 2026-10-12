import Foundation
import LocalAuthentication
import Observation

public enum AuthResult: Sendable, Equatable {
    case success
    case failed
    /// The phone has no passcode, so there is nothing to check against.
    case unavailable
}

public protocol Authenticator: Sendable {
    func authenticate(reason: String) async -> AuthResult
    var isAvailable: Bool { get }
}

/// Face ID, falling back to the passcode as the system offers.
public struct LocalAuthenticator: Authenticator {
    public init() {}

    public var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    public func authenticate(reason: String) async -> AuthResult {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return .unavailable }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
                ? .success : .failed
        } catch {
            return .failed
        }
    }
}

/// A paired phone can make agents do anything they can do, so the app locks after 5 minutes away.
@MainActor @Observable
public final class AppLock {
    public enum Phase: Sendable {
        case active, inactive, background
    }

    static let grace: TimeInterval = 5 * 60
    private static let enabledKey = "lockEnabled"

    public var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Self.enabledKey)
            if !isEnabled { isLocked = false }
        }
    }

    public private(set) var isLocked = false
    /// Hides the app while it is not in front, so the app switcher never shows an agent.
    public private(set) var isCovered = false
    public private(set) var isUnlocking = false
    /// Whether there is anything to guard: an unpaired phone reaches no agent, so it never locks.
    public var isGuarding = true {
        didSet { if !isGuarding { isLocked = false } }
    }

    private let defaults: UserDefaults
    private let authenticator: any Authenticator
    private let now: @Sendable () -> Date
    private var awaySince: Date?

    public init(
        defaults: UserDefaults = .standard, authenticator: any Authenticator = LocalAuthenticator(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.authenticator = authenticator
        self.now = now
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    /// Whether this phone has a passcode or Face ID to lock with.
    public var canLock: Bool { authenticator.isAvailable }

    public func launch() {
        isLocked = isEnabled && isGuarding
    }

    public func phaseChanged(to phase: Phase) {
        switch phase {
        case .inactive:
            isCovered = isEnabled
        case .background:
            isCovered = isEnabled
            if awaySince == nil { awaySince = now() }
        case .active:
            isCovered = false
            if let awaySince, isEnabled, isGuarding, now().timeIntervalSince(awaySince) >= Self.grace {
                isLocked = true
            }
            awaySince = nil
        }
    }

    public func unlock() async {
        guard isLocked, !isUnlocking else { return }
        isUnlocking = true
        defer { isUnlocking = false }
        switch await authenticator.authenticate(reason: "Unlock Canopy to see and answer your agents.") {
        case .success, .unavailable: isLocked = false
        case .failed: break
        }
    }
}
