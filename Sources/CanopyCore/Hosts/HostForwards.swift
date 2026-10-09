import Foundation
import Synchronization

/// Where a remote port is reached on the Mac: its forward's port, or why it has none.
public struct PortForward: Sendable, Equatable {
    public var local: UInt16?
    /// ssh's message from the last try, once the forward gave up.
    public var error: String?

    public init(local: UInt16?, error: String?) {
        self.local = local
        self.error = error
    }
}

/// The Mac ports every host's forwards hold or are trying, so hosts forwarding at the same time never pick the same
/// one. A port is taken here before its forward is tried, and given back when the try fails or the forward goes.
public final class MacPortReservations: Sendable {
    private let owners = Mutex<[UInt16: ObjectIdentifier]>([:])

    public init() {}

    /// Takes the port for `owner` unless another holds it.
    func reserve(_ port: UInt16, for owner: ObjectIdentifier) -> Bool {
        owners.withLock { owners in
            guard owners[port].map({ $0 == owner }) ?? true else { return false }
            owners[port] = owner
            return true
        }
    }

    func release(_ port: UInt16, for owner: ObjectIdentifier) {
        owners.withLock { owners in
            if owners[port] == owner { owners[port] = nil }
        }
    }

    func releaseAll(for owner: ObjectIdentifier) {
        owners.withLock { owners in owners = owners.filter { $0.value != owner } }
    }

    /// The ports anyone holds.
    var held: Set<UInt16> { owners.withLock { Set($0.keys) } }
}

/// One host's forwards from Mac ports to the ports listening on it, through its master. It lives in the host's
/// `HostConnection` and runs in that actor's isolation, which runs one `apply` at a time.
final class HostForwards {
    struct Held: Equatable {
        var local: UInt16
        var target: String
    }

    /// A port is tried this many times a round, each on the next free Mac port, before the round gives up on it.
    static let tries = 20

    private let ssh: SSHCommand
    /// By remote port, including forwards no longer wanted whose cancel failed, which may still run in the master.
    private(set) var held: [UInt16: Held] = [:]
    /// Forwards a `-O forward` that timed out may have made, and whose cancel failed too. They keep their Mac ports
    /// until a later round cancels them.
    private var unsure: [(port: UInt16, forward: Held)] = []
    /// Moves on with every reset, so a round under way when the master stopped records nothing more.
    private var epoch = 0

    private let macPorts: MacPortReservations

    init(ssh: SSHCommand, macPorts: MacPortReservations) {
        self.ssh = ssh
        self.macPorts = macPorts
    }

    deinit {
        macPorts.releaseAll(for: ObjectIdentifier(self))
    }

    var localPorts: Set<UInt16> { Set(held.values.map(\.local) + unsure.map(\.forward.local)) }

    /// Forgets every forward, as the master that held them stopped, and gives their Mac ports back.
    func reset() {
        held = [:]
        unsure = []
        epoch += 1
        macPorts.releaseAll(for: ObjectIdentifier(self))
    }

    /// Cancels the forwards no longer wanted and makes the missing ones, each on its own port when that is free and
    /// no forward of this or another host holds it, else the next such port. A forward whose cancel fails is
    /// kept, and cancelled again next round. `run` returns nil once the master is gone, and the round then ends with
    /// nil, as it does when the master stopped meanwhile, since it says nothing of the forwards there are now.
    nonisolated(nonsending) func apply(
        _ wanted: [RemoteListeningPort], isFree: (UInt16) -> Bool,
        run: ([String]) async -> SubprocessResult?
    ) async -> [UInt16: PortForward]? {
        let start = epoch
        var stillUnsure: [(port: UInt16, forward: Held)] = []
        for entry in unsure {
            guard let cancelled = await cancel(entry.forward, port: entry.port, run: run), epoch == start else {
                return nil
            }
            if cancelled {
                macPorts.release(entry.forward.local, for: ObjectIdentifier(self))
            } else {
                stillUnsure.append(entry)
            }
        }
        unsure = stillUnsure
        let wantedTargets = Dictionary(wanted.map { ($0.port, $0.target) }, uniquingKeysWith: { first, _ in first })
        var moved: [UInt16: UInt16] = [:]
        for (port, forward) in held.sorted(by: { $0.key < $1.key }) where wantedTargets[port] != forward.target {
            guard let cancelled = await cancel(forward, port: port, run: run), epoch == start else { return nil }
            guard cancelled else { continue }
            held[port] = nil
            // A forward moving keeps its Mac port, so no other host takes it while it is forwarded again.
            if wantedTargets[port] != nil {
                moved[port] = forward.local
            } else {
                macPorts.release(forward.local, for: ObjectIdentifier(self))
            }
        }
        var forwards: [UInt16: PortForward] = [:]
        for port in wanted.sorted(by: { $0.port < $1.port }) where forwards[port.port] == nil {
            if let forward = held[port.port] {
                forwards[port.port] = PortForward(local: forward.local, error: nil)
                continue
            }
            let made = await forward(port, from: moved[port.port] ?? port.port, isFree: isFree, run: run)
            if let old = moved[port.port], made?.local != old, !localPorts.contains(old) {
                macPorts.release(old, for: ObjectIdentifier(self))
            }
            guard let made, epoch == start else { return nil }
            forwards[port.port] = made
        }
        return forwards
    }

    /// Whether ssh cancelled the forward, which it also does for one it does not have. Nil once the master is gone.
    nonisolated(nonsending) private func cancel(
        _ forward: Held, port: UInt16, run: ([String]) async -> SubprocessResult?
    ) async -> Bool? {
        guard let result = await run(ssh.cancelLocal(local: forward.local, target: forward.target, port: port)) else {
            return nil
        }
        return result.status == 0 && !result.timedOut
    }

    /// One port's forward, on the first Mac port from `first` up that ssh takes. A try that timed out may have made
    /// the forward all the same, so it is cancelled before the next port, and when that fails too the port is left
    /// for a later round. Nil once the master is gone.
    nonisolated(nonsending) private func forward(
        _ port: RemoteListeningPort, from first: UInt16, isFree: (UInt16) -> Bool,
        run: ([String]) async -> SubprocessResult?
    ) async -> PortForward? {
        let start = epoch
        let owner = ObjectIdentifier(self)
        var next = first
        var message = "No port from \(first) up is free on this Mac."
        for _ in 0..<Self.tries {
            // Taken before the try, so another host forwarding meanwhile picks another.
            guard
                let local = LocalPortChooser.port(
                    for: next, taken: localPorts, isFree: { isFree($0) && macPorts.reserve($0, for: owner) })
            else { break }
            let forward = Held(local: local, target: port.target)
            guard let result = await run(ssh.forwardLocal(local: local, target: port.target, port: port.port)),
                epoch == start
            else {
                macPorts.release(local, for: owner)
                return nil
            }
            if result.status == 0, !result.timedOut {
                held[port.port] = forward
                return PortForward(local: local, error: nil)
            }
            if result.timedOut {
                guard let cancelled = await cancel(forward, port: port.port, run: run), epoch == start else {
                    macPorts.release(local, for: owner)
                    return nil
                }
                guard cancelled else {
                    unsure.append((port.port, forward))
                    return PortForward(local: nil, error: "ssh did not answer while forwarding port \(local).")
                }
                message = "ssh did not answer while forwarding port \(local)."
                macPorts.release(local, for: owner)
            } else {
                macPorts.release(local, for: owner)
                let errors = String(decoding: result.stderr, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                message = errors.isEmpty ? "ssh exited \(result.status)." : errors
            }
            guard local < UInt16.max else { break }
            next = local + 1
        }
        return PortForward(local: nil, error: message)
    }
}
