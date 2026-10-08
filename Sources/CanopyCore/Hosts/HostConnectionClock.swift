import Foundation
import Synchronization

/// The time a host connection reads and waits on. Tests pass one whose sleeps pass at once.
public protocol HostClock: Sendable {
    var now: ContinuousClock.Instant { get }
    func sleep(for duration: Duration) async throws
}

public struct SystemHostClock: HostClock {
    public init() {}

    public var now: ContinuousClock.Instant { ContinuousClock.now }

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

/// A running ssh master.
public protocol HostMasterProcess: AnyObject, Sendable {
    var isRunning: Bool { get }
    /// What ssh last wrote to stderr, such as why it could not connect.
    var errorOutput: String { get }
    func stop()
    func waitForExit() async
}

/// Starts the processes a host connection needs. Tests pass one that plays ssh.
public protocol HostProcessLauncher: Sendable {
    func startMaster(_ argv: [String]) -> any HostMasterProcess
    func run(_ argv: [String], timeout: Duration?) async -> SubprocessResult
    /// Runs a host's `wake` command with the login shell's PATH, which tools like aws live on.
    func runWake(_ command: String) async -> SubprocessResult
}

public struct SubprocessHostLauncher: HostProcessLauncher {
    let environment: @Sendable () -> [String: String]

    /// ssh gets the login PATH, which a ProxyCommand such as `aws ssm start-session` needs.
    public init(environment: @escaping @Sendable () -> [String: String] = { GitEnvironment.current }) {
        self.environment = environment
    }

    public func startMaster(_ argv: [String]) -> any HostMasterProcess {
        SubprocessMaster(argv, environment: environment())
    }

    public func run(_ argv: [String], timeout: Duration?) async -> SubprocessResult {
        let environment = environment()
        return await onOwnThread {
            do {
                return try Subprocess.run(
                    argv[0], Array(argv.dropFirst()), environment: environment, directory: nil, timeout: timeout)
            } catch {
                return SubprocessResult(status: 255, stdout: Data(), stderr: Data("\(error)".utf8), timedOut: false)
            }
        }
    }

    public func runWake(_ command: String) async -> SubprocessResult {
        await run(["/bin/sh", "-c", command], timeout: .seconds(120))
    }
}

final class SubprocessMaster: HostMasterProcess {
    private let handle = SubprocessHandle()
    /// ssh's stderr once it has exited, when the handle no longer has it.
    private let finalErrors = Exited()
    private let finished: Task<Void, Never>

    init(_ argv: [String], environment: [String: String]) {
        let handle = self.handle
        let finalErrors = self.finalErrors
        finished = Task {
            let errors = await onOwnThread {
                do {
                    let result = try Subprocess.run(
                        argv[0], Array(argv.dropFirst()), environment: environment, directory: nil, timeout: nil,
                        handle: handle)
                    return String(decoding: result.stderr, as: UTF8.self)
                } catch {
                    return "\(error)"
                }
            }
            finalErrors.errors.withLock { $0 = errors }
        }
    }

    var isRunning: Bool { finalErrors.errors.withLock { $0 == nil } }

    var errorOutput: String {
        finalErrors.errors.withLock { $0 } ?? String(decoding: handle.errorOutput(), as: UTF8.self)
    }

    func stop() {
        handle.cancel()
    }

    func waitForExit() async {
        await finished.value
    }
}

private final class Exited: Sendable {
    let errors = Mutex<String?>(nil)
}
