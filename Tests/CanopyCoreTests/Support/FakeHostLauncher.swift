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

        var isRunning: Bool { !exited.withLock { $0 } }
        var errorOutput: String { "Connection closed by UNKNOWN port 65535" }

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
        var masters: [Master] = []
        var wakes: [String] = []
        var commands: [[String]] = []
        /// Whether the control socket's file was there as each master started.
        var socketThereAtStart: [Bool] = []
        /// Masters whose socket is gone while their process lingers, as after a dropped connection.
        var deadSockets: Set<ObjectIdentifier> = []
    }

    let state = Mutex(State())

    var masterUp: Bool {
        get { state.withLock { $0.masterUp } }
        set { state.withLock { $0.masterUp = newValue } }
    }
    var masters: [Master] { state.withLock { $0.masters } }
    var wakes: [String] { state.withLock { $0.wakes } }
    var commands: [[String]] { state.withLock { $0.commands } }

    func startMaster(_ argv: [String]) -> any HostMasterProcess {
        let master = Master()
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
            let last = masters.last
            let up = (last?.isRunning ?? false) && !state.withLock { $0.deadSockets.contains(ObjectIdentifier(last!)) }
            return SubprocessResult(status: up ? 0 : 255, stdout: Data(), stderr: Data(), timedOut: false)
        }
        return SubprocessResult(status: 0, stdout: Data(), stderr: Data(), timedOut: false)
    }

    func runWake(_ command: String) async -> SubprocessResult {
        state.withLock { $0.wakes.append(command) }
        return SubprocessResult(status: 0, stdout: Data(), stderr: Data(), timedOut: false)
    }
}
