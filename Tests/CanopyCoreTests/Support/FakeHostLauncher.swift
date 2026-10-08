import Foundation
import Synchronization

@testable import CanopyCore

/// A clock whose sleeps pass at once, moving its time forward by what was asked.
final class TestHostClock: HostClock {
    private let time = Mutex(ContinuousClock.now)

    var now: ContinuousClock.Instant { time.withLock { $0 } }

    func advance(by duration: Duration) {
        time.withLock { $0 += duration }
    }

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        advance(by: duration)
        await Task.yield()
    }
}

/// Plays ssh for `HostConnection`: masters come up or fail as `masterUp` says, and every command is recorded.
final class FakeHostLauncher: HostProcessLauncher {
    final class Master: HostMasterProcess {
        let exited = Mutex(false)
        let waiters = Mutex<[CheckedContinuation<Void, Never>]>([])
        let errorOutput: String

        init(errorOutput: String) {
            self.errorOutput = errorOutput
        }

        var isRunning: Bool { !exited.withLock { $0 } }

        func stop() { end() }

        func end() {
            exited.withLock { $0 = true }
            for waiter in waiters.withLock({ list in
                defer { list = [] }; return list
            }) { waiter.resume() }
        }

        func waitForExit() async {
            await withCheckedContinuation { continuation in
                let done = exited.withLock { exited in
                    if !exited { waiters.withLock { $0.append(continuation) } }
                    return exited
                }
                if done { continuation.resume() }
            }
        }
    }

    struct State {
        var masterUp: Bool = true
        /// The status of commands run through the master.
        var execStatus: Int32 = 0
        /// What a master that does not come up says.
        var masterError = "Connection closed by UNKNOWN port 65535"
        var masters: [Master] = []
        var wakes: [String] = []
        var commands: [[String]] = []
        /// Whether the control socket's file was there as each master started.
        var socketThereAtStart: [Bool] = []
        /// Masters whose socket is gone while their process lingers, as after a dropped connection.
        var deadSockets: Set<ObjectIdentifier> = []
        /// Wakes wait here until `releaseWakes()`, as a host that takes its time to start.
        var holdWakes = false
        var heldWakes: [CheckedContinuation<Void, Never>] = []
        /// Mac ports `-O forward -L` fails on, as when something holds both loopbacks there, or every one.
        var refusedPorts: Set<UInt16> = []
        var refuseEveryPort = false
        /// `-O check` waits here until it is released.
        var holdChecks = false
        var heldChecks: [CheckedContinuation<Void, Never>] = []
    }

    let state = Mutex(State())

    var masterUp: Bool {
        get { state.withLock { $0.masterUp } }
        set { state.withLock { $0.masterUp = newValue } }
    }
    var masterError: String {
        get { state.withLock { $0.masterError } }
        set { state.withLock { $0.masterError = newValue } }
    }
    var execStatus: Int32 {
        get { state.withLock { $0.execStatus } }
        set { state.withLock { $0.execStatus = newValue } }
    }
    var holdChecks: Bool {
        get { state.withLock { $0.holdChecks } }
        set { state.withLock { $0.holdChecks = newValue } }
    }
    func heldCheckCount() -> Int { state.withLock { $0.heldChecks.count } }

    static let refusal = "mux_client_forward: forwarding request failed: Port forwarding failed"

    func refuse(_ ports: Set<UInt16>) {
        state.withLock { $0.refusedPorts = ports }
    }

    func refuseEveryPort(_ refuse: Bool) {
        state.withLock { $0.refuseEveryPort = refuse }
    }

    /// The `-L` words of each `-O <operation>` run, in order.
    func localForwards(_ operation: String) -> [String] {
        commands.compactMap { argv in
            guard argv.containsSequence(["-O", operation]), let at = argv.firstIndex(of: "-L") else { return nil }
            return argv[at + 1]
        }
    }

    func releaseFirstCheck() {
        let first = state.withLock { state in state.heldChecks.isEmpty ? nil : state.heldChecks.removeFirst() }
        first?.resume()
    }

    func releaseChecks() {
        let held = state.withLock { state in
            state.holdChecks = false
            defer { state.heldChecks = [] }
            return state.heldChecks
        }
        for check in held { check.resume() }
    }

    var holdWakes: Bool {
        get { state.withLock { $0.holdWakes } }
        set { state.withLock { $0.holdWakes = newValue } }
    }
    var masters: [Master] { state.withLock { $0.masters } }
    var wakes: [String] { state.withLock { $0.wakes } }
    var commands: [[String]] { state.withLock { $0.commands } }

    func startMaster(_ argv: [String]) -> any HostMasterProcess {
        let master = Master(errorOutput: state.withLock { $0.masterError })
        let control = argv.firstIndex(of: "-S").map { argv[$0 + 1] } ?? ""
        let there = FileManager.default.fileExists(atPath: control)
        let up = state.withLock { state in
            state.socketThereAtStart.append(there)
            state.masters.append(master)
            return state.masterUp
        }
        if !up { master.end() }
        return master
    }

    func run(_ argv: [String], timeout: Duration?) async -> SubprocessResult {
        state.withLock { $0.commands.append(argv) }
        if argv.containsSequence(["-O", "check"]) {
            // ssh asks the socket as it is now, however long the answer takes to arrive.
            let last = masters.last
            let up = (last?.isRunning ?? false) && !state.withLock { $0.deadSockets.contains(ObjectIdentifier(last!)) }
            await withCheckedContinuation { continuation in
                let held = state.withLock { state in
                    if state.holdChecks { state.heldChecks.append(continuation) }
                    return state.holdChecks
                }
                if !held { continuation.resume() }
            }
            return SubprocessResult(status: up ? 0 : 255, stdout: Data(), stderr: Data(), timedOut: false)
        }
        if argv.containsSequence(["-O", "forward"]), let at = argv.firstIndex(of: "-L"),
            let local = argv[at + 1].split(separator: ":").first.flatMap({ UInt16($0) }),
            state.withLock({ $0.refuseEveryPort || $0.refusedPorts.contains(local) })
        {
            return SubprocessResult(
                status: 255, stdout: Data(), stderr: Data((Self.refusal + "\n").utf8), timedOut: false)
        }
        return SubprocessResult(status: execStatus, stdout: Data(), stderr: Data(), timedOut: false)
    }

    func runWake(_ command: String) async -> SubprocessResult {
        let hold = state.withLock { state in
            state.wakes.append(command)
            return state.holdWakes
        }
        if hold {
            await withCheckedContinuation { continuation in
                let held = state.withLock { state in
                    if state.holdWakes { state.heldWakes.append(continuation) }
                    return state.holdWakes
                }
                if !held { continuation.resume() }
            }
        }
        return SubprocessResult(status: 0, stdout: Data(), stderr: Data(), timedOut: false)
    }

    func releaseWakes() {
        let held = state.withLock { state in
            state.holdWakes = false
            defer { state.heldWakes = [] }
            return state.heldWakes
        }
        for wake in held { wake.resume() }
    }
}
