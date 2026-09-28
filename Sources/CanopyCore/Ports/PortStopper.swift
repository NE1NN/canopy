import Foundation

/// Stops the processes listening on ports: SIGTERM first, then SIGKILL for any still listening after a grace period.
public struct PortStopper: Sendable {
    public var grace: Duration
    private let scan: @Sendable () -> [ListeningPort]

    public init(
        grace: Duration = .seconds(3),
        scan: @escaping @Sendable () -> [ListeningPort] = { PortScanner.listeningPorts() }
    ) {
        self.grace = grace
        self.scan = scan
    }

    public struct Outcome: Sendable, Equatable {
        /// Processes that were still listening after the grace period and got SIGKILL.
        public var killed: [pid_t]
    }

    /// Returns once every process has let go of its ports, or has been killed. Canopy itself and launchd are never
    /// signalled.
    public func stop(_ ports: [ListeningPort]) async -> Outcome {
        let targets = ports.filter { $0.pid > 1 && $0.pid != getpid() }
        for pid in Set(targets.map(\.pid)) {
            kill(pid, SIGTERM)
            // A server paused with Ctrl-Z would only take SIGTERM once resumed, as shells know.
            kill(pid, SIGCONT)
        }
        let deadline = ContinuousClock.now + grace
        var holding = await stillListening(targets)
        while !holding.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            holding = await stillListening(targets)
        }
        let killed = Set(holding.map(\.pid)).sorted()
        for pid in killed {
            kill(pid, SIGKILL)
        }
        return Outcome(killed: killed)
    }

    private func stillListening(_ targets: [ListeningPort]) async -> [ListeningPort] {
        let scan = scan
        let listening = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: Set(scan().map { PortKey($0) })) }
        }
        return targets.filter { listening.contains(PortKey($0)) }
    }

    private struct PortKey: Hashable {
        var port: UInt16
        var pid: pid_t

        init(_ port: ListeningPort) {
            self.port = port.port
            self.pid = port.pid
        }
    }
}
