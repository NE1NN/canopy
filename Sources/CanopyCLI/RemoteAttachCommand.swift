import ArgumentParser
import CanopyCore
import Darwin
import Foundation

/// What a remote pane runs: the pane's tmux session on its host, joined again whenever the connection comes back.
struct RemoteAttachCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remote-attach", abstract: "Run a remote pane's session on its host.", shouldDisplay: false)

    func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let pane = environment["CANOPY_PANE"], !pane.isEmpty else {
            FileHandle.standardError.write(Data("canopy remote-attach runs in a Canopy terminal.\n".utf8))
            throw ExitCode(2)
        }
        let app = AttachClient(socket: CanopyHome.resolve(bundleHome: AppLocator.bundleHome()).socketPath)
        let loop = RemoteAttachLoop(
            attach: { try app.call(HostAttachMethod.attach, HostAttachParams(pane: pane), as: HostAttachResult.self) },
            next: { status in
                try app.call(HostAttachMethod.next, HostNextParams(pane: pane, status: status), as: HostNextResult.self)
            },
            runSSH: { argv in await Foreground.run(argv) },
            print: { text in FileHandle.standardOutput.write(Data("\u{1b}[2m\(text)\u{1b}[0m\r\n".utf8)) },
            readLine: { await Foreground.readLine() },
            pause: { try? await Task.sleep(for: $0) })
        throw ExitCode(await loop.run())
    }
}

/// The app, reached without launching it: a remote pane only runs while the app does.
struct AttachClient: Sendable {
    let socket: String

    func call<Result: Decodable>(_ method: String, _ params: some Encodable, as: Result.Type) throws -> Result {
        let response = try ControlClient(socketPath: socket, timeout: 60).send(
            ControlRequest(method: method, params: try .from(params)))
        if let error = response.error { throw RemoteAttachError(message: error.message) }
        return try (response.result ?? .null).decode(Result.self)
    }
}

struct RemoteAttachError: Error, CustomStringConvertible {
    var message: String
    var description: String { message }
}
