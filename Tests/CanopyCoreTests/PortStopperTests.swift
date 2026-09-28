import Foundation
import Testing

@testable import CanopyCore

/// A perl process listening on a free loopback port, which it holds until it exits.
struct ListeningChild {
    let process: Process
    let port: ListeningPort

    static func start(in folder: String? = nil, ignoringSIGTERM: Bool = false) async throws -> ListeningChild {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [
            "-MIO::Socket::INET", "-e",
            #"$SIG{TERM} = "IGNORE" if $ARGV[0]; my $s = IO::Socket::INET->new(Listen => 5, LocalAddr => "127.0.0.1", LocalPort => 0) or die $!; sleep 120"#,
            ignoringSIGTERM ? "1" : "0",
        ]
        if let folder { process.currentDirectoryURL = URL(fileURLWithPath: folder) }
        try process.run()
        let pid = process.processIdentifier
        var found: ListeningPort?
        _ = await eventually {
            found = PortScanner.listeningPorts().first { $0.pid == pid }
            return found != nil
        }
        guard let found else {
            process.terminate()
            throw POSIXError(.ETIMEDOUT)
        }
        return ListeningChild(process: process, port: found)
    }
}

struct PortStopperTests {
    @Test func stopsAProcessWithSIGTERM() async throws {
        let child = try await ListeningChild.start()

        let outcome = await PortStopper(grace: .seconds(10)).stop([child.port])

        #expect(outcome.killed.isEmpty)
        #expect(await eventually { !child.process.isRunning })
        #expect(child.process.terminationReason == .uncaughtSignal && child.process.terminationStatus == SIGTERM)
    }

    @Test func killsAProcessThatIgnoresSIGTERM() async throws {
        let child = try await ListeningChild.start(ignoringSIGTERM: true)

        let outcome = await PortStopper(grace: .milliseconds(300)).stop([child.port])

        #expect(outcome.killed == [child.port.pid])
        #expect(await eventually { !child.process.isRunning })
        #expect(child.process.terminationStatus == SIGKILL)
    }

    @Test func neverSignalsItselfOrLaunchd() async {
        let outcome = await PortStopper(grace: .milliseconds(100)).stop([
            ListeningPort(port: 1, pid: getpid(), process: "self"), ListeningPort(port: 2, pid: 1, process: "launchd"),
        ])

        #expect(outcome.killed.isEmpty)
    }
}
