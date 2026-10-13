import Foundation

public struct GitError: Error, Sendable, Equatable, CustomStringConvertible {
    public var arguments: [String]
    public var exitCode: Int32
    public var stderr: String
    public var timedOut = false
    /// ssh could not reach the host git was to run on, so git never ran.
    public var hostUnreachable = false

    public init(
        arguments: [String], exitCode: Int32, stderr: String, timedOut: Bool = false, hostUnreachable: Bool = false
    ) {
        self.arguments = arguments
        self.exitCode = exitCode
        self.stderr = stderr
        self.timedOut = timedOut
        self.hostUnreachable = hostUnreachable
    }

    public var description: String {
        if timedOut { return "git \(arguments.first ?? "") timed out" }
        if hostUnreachable {
            let reason = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return reason.isEmpty ? "ssh could not reach the host" : reason
        }
        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "git \(arguments.joined(separator: " ")) exited with \(exitCode)" : message
    }
}
