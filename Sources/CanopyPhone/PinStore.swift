import Foundation
import Observation

/// The rows pinned to the top of the inbox. Pins live on the phone, by row path.
@MainActor @Observable
public final class PinStore {
    public private(set) var pins: [String]
    /// Whether the author pinned or unpinned anything, or the first launch's pins were already taken.
    public private(set) var isSettled: Bool

    private let defaults: UserDefaults
    private static let pinsKey = "pins"
    private static let settledKey = "pinsSettled"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pins = defaults.stringArray(forKey: Self.pinsKey) ?? []
        isSettled = defaults.bool(forKey: Self.settledKey)
    }

    public func toggle(_ path: String) {
        if let index = pins.firstIndex(of: path) {
            pins.remove(at: index)
        } else {
            pins.append(path)
        }
        settle()
    }

    /// The first launch's pins, taken once there are any.
    public func adoptDefaults(_ paths: [String]) {
        guard !isSettled, !paths.isEmpty else { return }
        pins = paths
        settle()
    }

    private func settle() {
        isSettled = true
        defaults.set(pins, forKey: Self.pinsKey)
        defaults.set(true, forKey: Self.settledKey)
    }
}
