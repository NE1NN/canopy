import Foundation
import Testing

@testable import CanopyCore

/// A perl process listening on a free loopback port, which it holds until it exits.
struct ListeningChild {
    /// Perl code that binds `$s` to a free port below the system's random range, as dev servers' ports are.
    static let bindSparePort =
        #"my $s; for (1..200) { $s = IO::Socket::INET->new(Listen => 5, LocalAddr => "127.0.0.1", LocalPort => 20000 + int(rand(20000))) and last } $s or die $!;"#

    let process: Process
    let port: ListeningPort

    enum OnSIGTERM: String {
        case die, ignore
        /// Exits cleanly from a handler, as servers that shut down gracefully do.
        case exit
    }

    /// `anyPort` binds port 0, so the system picks one from its random range.
    static func start(in folder: String? = nil, onSIGTERM: OnSIGTERM = .die, anyPort: Bool = false) async throws
        -> ListeningChild
    {
        let bind =
            anyPort
            ? #"my $s = IO::Socket::INET->new(Listen => 5, LocalAddr => "127.0.0.1", LocalPort => 0) or die $!;"#
            : bindSparePort
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [
            "-MIO::Socket::INET", "-e",
            #"$SIG{TERM} = "IGNORE" if $ARGV[0] eq "ignore"; $SIG{TERM} = sub { exit 0 } if $ARGV[0] eq "exit"; "#
                + bind + " sleep 120",
            onSIGTERM.rawValue,
        ]
        if let folder { process.currentDirectoryURL = URL(fileURLWithPath: folder) }
        try process.run()
        let pid = process.processIdentifier
        var found: ListeningPort?
        _ = await eventually {
            found = (try? await offPool { PortScanner.listeningPorts() })?.first { $0.pid == pid }
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

        defer { child.process.terminate() }

        let outcome = await PortStopper(grace: .seconds(10)).stop([child.port])

        #expect(outcome.killed.isEmpty)
        #expect(await eventually { !child.process.isRunning })
        #expect(child.process.terminationReason == .uncaughtSignal && child.process.terminationStatus == SIGTERM)
    }

    @Test func killsAProcessThatIgnoresSIGTERM() async throws {
        let child = try await ListeningChild.start(onSIGTERM: .ignore)
        defer { kill(child.port.pid, SIGKILL) }

        let outcome = await PortStopper(grace: .milliseconds(300)).stop([child.port])

        #expect(outcome.killed == [child.port.pid])
        #expect(await eventually { !child.process.isRunning })
        #expect(child.process.terminationStatus == SIGKILL)
    }

    /// A server paused with Ctrl-Z would hold SIGTERM until resumed, and then be killed without shutting down.
    @Test func resumesAPausedProcessSoItsSIGTERMHandlerRuns() async throws {
        let child = try await ListeningChild.start(onSIGTERM: .exit)
        defer { kill(child.port.pid, SIGKILL) }
        kill(child.port.pid, SIGSTOP)

        let outcome = await PortStopper(grace: .seconds(10)).stop([child.port])

        #expect(outcome.killed.isEmpty)
        #expect(await eventually { !child.process.isRunning })
        #expect(child.process.terminationReason == .exit && child.process.terminationStatus == 0)
    }

    @Test func neverSignalsItselfOrLaunchd() async {
        let outcome = await PortStopper(grace: .milliseconds(100)).stop([
            ListeningPort(port: 1, pid: getpid(), process: "self"), ListeningPort(port: 2, pid: 1, process: "launchd"),
        ])

        #expect(outcome.killed.isEmpty)
    }
}
