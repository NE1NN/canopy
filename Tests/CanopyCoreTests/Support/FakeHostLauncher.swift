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
        /// What a master that does not come up says.
        var masterError = "Connection closed by UNKNOWN port 65535"
        /// What `ssh -G` prints.
        var config = "hostname box.example.com\n"
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
    var config: String {
        get { state.withLock { $0.config } }
        set { state.withLock { $0.config = newValue } }
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
        if argv.contains("-G") {
            return SubprocessResult(status: 0, stdout: Data(config.utf8), stderr: Data(), timedOut: false)
        }
        if argv.containsSequence(["-O", "check"]) {
            let last = masters.last
            let up = (last?.isRunning ?? false) && !state.withLock { $0.deadSockets.contains(ObjectIdentifier(last!)) }
            return SubprocessResult(status: up ? 0 : 255, stdout: Data(), stderr: Data(), timedOut: false)
        }
        return SubprocessResult(status: 0, stdout: Data(), stderr: Data(), timedOut: false)
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
