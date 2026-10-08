import Foundation

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
    /// By remote port.
    private(set) var held: [UInt16: Held] = [:]
    /// Moves on with every reset, so a round under way when the master stopped records nothing more.
    private var epoch = 0

    init(ssh: SSHCommand) {
        self.ssh = ssh
    }

    var localPorts: Set<UInt16> { Set(held.values.map(\.local)) }

    /// Forgets every forward, as the master that held them stopped.
    func reset() {
        held = [:]
        epoch += 1
    }

    /// Cancels the forwards no longer wanted and makes the missing ones, each on its own port when that is free and
    /// no forward of this or another host (`taken`) holds it, else the next such port. `run` returns nil once the
    /// master is gone, which ends the round with no forwards.
    nonisolated(nonsending) func apply(
        _ wanted: [RemoteListeningPort], taken: Set<UInt16>, isFree: (UInt16) -> Bool,
        run: ([String]) async -> SubprocessResult?
    ) async -> [UInt16: PortForward] {
        let start = epoch
        let wantedTargets = Dictionary(wanted.map { ($0.port, $0.target) }, uniquingKeysWith: { first, _ in first })
        var moved: [UInt16: UInt16] = [:]
        for (port, forward) in held.sorted(by: { $0.key < $1.key }) where wantedTargets[port] != forward.target {
            guard await run(ssh.cancelLocal(local: forward.local, target: forward.target, port: port)) != nil,
                epoch == start
            else { return [:] }
            held[port] = nil
            if wantedTargets[port] != nil { moved[port] = forward.local }
        }
        var forwards: [UInt16: PortForward] = [:]
        for port in wanted.sorted(by: { $0.port < $1.port }) where forwards[port.port] == nil {
            if let forward = held[port.port] {
                forwards[port.port] = PortForward(local: forward.local, error: nil)
                continue
            }
            guard
                let made = await forward(
                    port, from: moved[port.port] ?? port.port, taken: taken, isFree: isFree, run: run),
                epoch == start
            else { return [:] }
            forwards[port.port] = made
        }
        return forwards
    }

    /// One port's forward, on the first Mac port from `first` up that ssh takes. Nil once the master is gone.
    nonisolated(nonsending) private func forward(
        _ port: RemoteListeningPort, from first: UInt16, taken: Set<UInt16>, isFree: (UInt16) -> Bool,
        run: ([String]) async -> SubprocessResult?
    ) async -> PortForward? {
        let start = epoch
        var next = first
        var message = "No port from \(first) up is free on this Mac."
        for _ in 0..<Self.tries {
            guard let local = LocalPortChooser.port(for: next, taken: taken.union(localPorts), isFree: isFree) else {
                break
            }
            guard let result = await run(ssh.forwardLocal(local: local, target: port.target, port: port.port)),
                epoch == start
            else { return nil }
            if result.status == 0 {
                held[port.port] = Held(local: local, target: port.target)
                return PortForward(local: local, error: nil)
            }
            let errors = String(decoding: result.stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            message = errors.isEmpty ? "ssh exited \(result.status)." : errors
            guard local < UInt16.max else { break }
            next = local + 1
        }
        return PortForward(local: nil, error: message)
    }
}
