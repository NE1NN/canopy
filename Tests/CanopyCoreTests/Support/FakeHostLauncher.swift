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
        /// Mac ports `-O forward -L` times out on, as when the master is slow to answer.
        var timedOutPorts: Set<UInt16> = []
        /// `-O cancel` fails, as when the master is slow to answer.
        var failCancels = false
        /// `-O forward -L` waits here until it is released.
        var holdForwards = false
        var heldForwards: [CheckedContinuation<Void, Never>] = []
        /// `-O check` waits here until it is released.
        var holdChecks = false
        var heldChecks: [CheckedContinuation<Void, Never>] = []
        /// What `canopy-host probe` prints, by kind, when set.
        var probeOutput: [Probe: String] = [:]
        /// Probes of these kinds wait until released, or until the task waiting for them is cancelled.
        var heldKinds: Set<Probe> = []
        var heldProbes: [Probe: [UUID: CheckedContinuation<Void, Never>]] = [:]
    }

    /// `canopy-host probe`, and with `--ports`, its ports probe.
    enum Probe: Hashable {
        case sessions, ports

        init?(_ argv: [String]) {
            let line = argv.joined(separator: " ")
            guard line.contains(#"canopy-host" probe"#) else { return nil }
            self = line.contains("--ports") ? .ports : .sessions
        }
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

    func timeOut(_ ports: Set<UInt16>) {
        state.withLock { $0.timedOutPorts = ports }
    }

    var failCancels: Bool {
        get { state.withLock { $0.failCancels } }
        set { state.withLock { $0.failCancels = newValue } }
    }

    var holdForwards: Bool {
        get { state.withLock { $0.holdForwards } }
        set { state.withLock { $0.holdForwards = newValue } }
    }

    func heldForwardCount() -> Int { state.withLock { $0.heldForwards.count } }

    func releaseFirstForward() {
        let first = state.withLock { state in state.heldForwards.isEmpty ? nil : state.heldForwards.removeFirst() }
        first?.resume()
    }

    func releaseForwards() {
        let held = state.withLock { state in
            state.holdForwards = false
            defer { state.heldForwards = [] }
            return state.heldForwards
        }
        for forward in held { forward.resume() }
    }

    /// The `-L` words of each `-O <operation>` run, in order.
    func localForwards(_ operation: String) -> [String] {
        commands.compactMap { argv in
            guard argv.containsSequence(["-O", operation]), let at = argv.firstIndex(of: "-L") else { return nil }
            return argv[at + 1]
        }
    }

    /// Probes of `kind` print `output`, with status 0.
    func answer(_ kind: Probe, with output: String) {
        state.withLock { $0.probeOutput[kind] = output }
    }

    func hold(_ kind: Probe) {
        state.withLock { _ = $0.heldKinds.insert(kind) }
    }

    func release(_ kind: Probe) {
        let held = state.withLock { state in
            state.heldKinds.remove(kind)
            defer { state.heldProbes[kind] = [:] }
            return state.heldProbes[kind] ?? [:]
        }
        for probe in held.values { probe.resume() }
    }

    /// The probes of `kind` waiting to be released.
    func heldProbeCount(_ kind: Probe) -> Int {
        state.withLock { $0.heldProbes[kind]?.count ?? 0 }
    }

    /// The probes of `kind` run so far, held ones included.
    func probes(_ kind: Probe) -> Int {
        commands.filter { Probe($0) == kind }.count
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
            let local = argv[at + 1].split(separator: ":").first.flatMap({ UInt16($0) })
        {
            await withCheckedContinuation { continuation in
                let held = state.withLock { state in
                    if state.holdForwards { state.heldForwards.append(continuation) }
                    return state.holdForwards
                }
                if !held { continuation.resume() }
            }
            if state.withLock({ $0.refuseEveryPort || $0.refusedPorts.contains(local) }) {
                return SubprocessResult(
                    status: 255, stdout: Data(), stderr: Data((Self.refusal + "\n").utf8), timedOut: false)
            }
            if state.withLock({ $0.timedOutPorts.contains(local) }) {
                return SubprocessResult(status: 137, stdout: Data(), stderr: Data(), timedOut: true)
            }
        }
        if argv.containsSequence(["-O", "cancel"]), failCancels {
            return SubprocessResult(
                status: 255, stdout: Data(), stderr: Data("mux_client_request_session: read from master failed".utf8),
                timedOut: false)
        }
        if let kind = Probe(argv) {
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let held = state.withLock { state in
                        let held = state.heldKinds.contains(kind) && !Task.isCancelled
                        if held { state.heldProbes[kind, default: [:]][id] = continuation }
                        return held
                    }
                    if !held { continuation.resume() }
                }
            } onCancel: {
                state.withLock { $0.heldProbes[kind]?.removeValue(forKey: id) }?.resume()
            }
            if let output = state.withLock({ $0.probeOutput[kind] }) {
                return SubprocessResult(status: 0, stdout: Data(output.utf8), stderr: Data(), timedOut: false)
            }
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
