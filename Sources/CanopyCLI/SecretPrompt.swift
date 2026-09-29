import CanopyTickets
import Darwin
import Foundation

/// Reads a secret such as a token: from the terminal without echoing it, or from stdin when it is piped in.
enum SecretPrompt {
    static func read(prompt: String) throws -> String {
        guard isatty(STDIN_FILENO) != 0 else {
            do {
                return try TokenInput.read(from: STDIN_FILENO, timeout: .seconds(10))
            } catch .timedOut {
                throw CLIError(
                    "No token arrived on stdin within 10 seconds: end it with a newline, or close stdin after it. Run "
                        + "this in a terminal to type it, or pipe it in: printf '%s\\n' \"$TOKEN\" | canopy ticket connect <url>"
                )
            } catch .tooLong {
                throw CLIError("The first line on stdin is longer than any token. Pipe in the token alone.")
            } catch .failed(let reason) {
                throw CLIError("Could not read the token from stdin: \(reason).")
            }
        }
        var buffer = [CChar](repeating: 0, count: 4096)
        defer { buffer.withUnsafeMutableBufferPointer { $0.update(repeating: 0) } }
        guard let read = readpassphrase(prompt, &buffer, buffer.count, RPP_REQUIRE_TTY) else {
            throw CLIError("Could not read the token from the terminal: \(String(cString: strerror(errno))).")
        }
        return String(cString: read).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
