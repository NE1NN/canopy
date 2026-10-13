import CanopyTestSupport
import Foundation
import Testing

@testable import CanopyCore

/// The host's relay script, run here against a home of the test's own.
struct RelayBoxSocketTests {
    /// Takes one request line and answers it as the app does, saying which socket it came to.
    static func answering(at path: String, as name: String) throws -> UnixListener {
        try UnixListener(path: path) { connection in
            guard (try? connection.readLine(deadline: .now + .seconds(10))) != nil else { return }
            var line = try! JSONEncoder().encode(RelayReply(stdout: Data(name.utf8), stderr: Data(), status: 0))
            line.append(0x0A)
            try? connection.write(Data("{\"ack\": true}\n".utf8) + line, deadline: .now + .seconds(5))
            connection.close()
        }
    }

    @Test func theRelayUsesTheBoxOnlyWhileItsSocketExists() async throws {
        let dir = try TempDir(in: "/tmp")
        let homeID = "c0c0c0c0"
        let script = dir.sub("canopy-host")
        try HostFiles.script.write(toFile: script, atomically: true, encoding: .utf8)
        let app = try Self.answering(at: dir.sub("app.sock"), as: "app")
        defer { app.close() }
        var environment = Fixture.environment
        environment["HOME"] = dir.path
        environment["CANOPY_HOME_ID"] = homeID
        environment["CANOPY_SOCKET"] = dir.sub("app.sock")
        let fixed = environment
        func run() async throws -> String {
            let result = try await offPool {
                try Subprocess.run(
                    "/usr/bin/python3", [script, "relay", "row", "list"], environment: fixed, directory: dir.path,
                    timeout: .seconds(30))
            }
            return String(decoding: result.stdout, as: UTF8.self)
        }
        #expect(try await run() == "app")
        let box = try Self.answering(at: dir.sub(".canopy/\(homeID)/box/box.sock"), as: "box")
        #expect(try await run() == "box")
        box.close()
        #expect(try await run() == "app")
    }
}
