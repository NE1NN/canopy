import CanopyGit
import CanopySystem
import CanopyWire
import Dispatch
import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// `canopy-box`'s commands: `version`, and `serve`, which runs the daemon for one Canopy home until SIGTERM or SIGINT.
public enum BoxMain {
    static let usage = "usage: canopy-box version | serve --home-id <id> [--root <folder>]"
    /// How often panes are read, the busy file is touched, and kept reports are looked for.
    static let pollEvery = Duration.seconds(2)
    static let replayEvery = Duration.seconds(30)

    /// Runs a command, returning its exit status. `serve` returns only when it cannot start.
    public static func run(_ arguments: [String]) async -> Int32 {
        switch arguments.first {
        case "version":
            print(CanopyVersion.current)
            return 0
        case "serve":
            return await serve(Array(arguments.dropFirst()))
        default:
            printError(usage)
            return 2
        }
    }

    private static func serve(_ arguments: [String]) async -> Int32 {
        var homeID: String?
        var root = ProcessInfo.processInfo.environment["HOME"] ?? Paths.homeDirectory
        var rest = arguments[...]
        while let flag = rest.popFirst() {
            switch (flag, rest.popFirst()) {
            case ("--home-id", let value?): homeID = value
            case ("--root", let value?): root = value
            default:
                printError(usage)
                return 2
            }
        }
        guard let homeID, homeID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }), !homeID.isEmpty
        else {
            printError(usage)
            return 2
        }
        signal(SIGPIPE, SIG_IGN)
        let paths = BoxPaths(root: Paths.canonical(root), homeID: homeID)
        var environment = ProcessInfo.processInfo.environment
        environment["TMUX"] = nil
        let tmux = Tmux(
            server: HostLayout.tmuxServer(homeID: homeID),
            config: FileManager.default.fileExists(atPath: paths.tmuxConf) ? paths.tmuxConf : nil,
            environment: environment)
        let git = Tmux.find("git", path: environment["PATH"]) ?? "/usr/bin/git"
        let gitEnvironment = environment
        let daemon = BoxDaemon(paths: paths, tmux: tmux) {
            GitClone.local(path: $0, executable: git, environment: gitEnvironment)
        }
        await daemon.start()
        let server: BoxServer
        do {
            server = try BoxServer(daemon: daemon, socketPath: paths.socket)
        } catch UnixSocketError.alreadyRunning(let path) {
            printError("canopy-box already runs for this home, on \(path).")
            return 1
        } catch {
            printError("canopy-box could not listen on \(paths.socket): \(error)")
            return 1
        }
        let stops = [SIGTERM, SIGINT].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler {
                server.close()
                exit(0)
            }
            source.resume()
            return source
        }
        await daemon.replayPending()
        await withDiscardingTaskGroup { group in
            group.addTask {
                while true {
                    await daemon.pollPanes()
                    try? await Task.sleep(for: pollEvery)
                }
            }
            group.addTask {
                while true {
                    await daemon.tickBusy()
                    try? await Task.sleep(for: BoxDaemon.busyEvery)
                }
            }
            group.addTask {
                while true {
                    try? await Task.sleep(for: replayEvery)
                    await daemon.replayPending()
                }
            }
        }
        withExtendedLifetime(stops) {}
        return 0
    }

    static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
