import Foundation
import Synchronization

public struct GitError: Error, Sendable, Equatable, CustomStringConvertible {
    public var arguments: [String]
    public var exitCode: Int32
    public var stderr: String

    public var description: String {
        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "git \(arguments.joined(separator: " ")) exited with \(exitCode)" : message
    }
}

public struct GitRunner: Sendable {
    public var executable: String

    public init(executable: String = "/usr/bin/git") {
        self.executable = executable
    }

    @discardableResult
    public func run(_ arguments: [String], in directory: String? = nil) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try runBlocking(arguments, in: directory) })
            }
        }
    }

    /// Runs git and reports only whether it exited 0. For probes like `show-ref --verify`.
    public func succeeds(_ arguments: [String], in directory: String? = nil) async -> Bool {
        (try? await run(arguments, in: directory)) != nil
    }

    private func runBlocking(_ arguments: [String], in directory: String?) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let directory {
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
        }
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "C"
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        try process.run()

        let errorData = Mutex(Data())
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            errorData.withLock { $0 = data }
        }
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw GitError(
                arguments: arguments,
                exitCode: process.terminationStatus,
                stderr: String(decoding: errorData.withLock { $0 }, as: UTF8.self)
            )
        }
        return String(decoding: outputData, as: UTF8.self)
    }
}
