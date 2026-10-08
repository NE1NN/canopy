import Foundation
import Synchronization
import Testing

@testable import CanopyCore

struct HostPathTests {
    /// A Mac's host name changes with its network, so the id is made once and kept in the home: a new one would leave
    /// every running session in a tmux server the panes no longer look for.
    @Test func homeIDsDifferByHomeAndStayTheSame() throws {
        let dir = try TempDir()
        let release = CanopyHome(path: dir.sub("release"))
        let dev = CanopyHome(path: dir.sub("dev"))

        let id = HomeID.load(home: release)

        #expect(id.count == 8)
        #expect(id.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(HomeID.load(home: release) == id)
        #expect(HomeID.load(home: CanopyHome(path: dir.sub("release"))) == id)
        #expect(HomeID.load(home: dev) != id)
        #expect(try String(contentsOf: release.homeIDFile, encoding: .utf8).trimmingCharacters(in: .newlines) == id)
    }

    @Test func appsStartingOnANewHomeAtOnceAgreeOnItsID() throws {
        for _ in 0..<20 {
            let dir = try TempDir()
            let home = CanopyHome(path: dir.sub("home"))
            let ids = Mutex<Set<String>>([])

            DispatchQueue.concurrentPerform(iterations: 8) { _ in
                let id = HomeID.load(home: home)
                ids.withLock { _ = $0.insert(id) }
            }

            #expect(ids.withLock { $0 } == [HomeID.load(home: home)])
        }
    }

    @Test func aHomeIDFileThatIsNotOneIsReplaced() throws {
        let dir = try TempDir()
        let home = CanopyHome(path: dir.sub("home"))
        try FileManager.default.createDirectory(at: home.root, withIntermediateDirectories: true)
        try "not an id".write(to: home.homeIDFile, atomically: true, encoding: .utf8)

        let id = HomeID.load(home: home)

        #expect(id.count == 8 && id.allSatisfy(\.isHexDigit))
        #expect(HomeID.load(home: home) == id)
    }

    @Test func socketsLiveInTheHomeWhenShortAndInTmpOtherwise() {
        let short = CanopyHome(path: "/Users/me/.canopy")
        let long = CanopyHome(path: "/Users/me/" + String(repeating: "x", count: 200))

        let control = HostPaths.controlSocket(home: short, homeID: "0123abcd", alias: "box", uid: 501)
        let hostSocket = HostPaths.hostSocket(home: short, homeID: "0123abcd", alias: "box", uid: 501)

        #expect(control.hasPrefix("/Users/me/.canopy/ssh/0123abcd-"))
        #expect(hostSocket.hasPrefix("/Users/me/.canopy/hosts/"))
        #expect(hostSocket.hasSuffix(".sock"))
        for path in [
            HostPaths.controlSocket(home: long, homeID: "0123abcd", alias: "box", uid: 501),
            HostPaths.hostSocket(home: long, homeID: "0123abcd", alias: "box", uid: 501),
        ] {
            #expect(path.hasPrefix("/tmp/canopy-501/"))
            #expect(path.utf8.count < 104)
        }
        #expect(
            HostPaths.controlSocket(home: short, homeID: "0123abcd", alias: "box", uid: 501)
                != HostPaths.controlSocket(home: short, homeID: "0123abcd", alias: "other", uid: 501))
        #expect(HostPaths.tmuxServer(homeID: "0123abcd") == "canopy-0123abcd")
        // ssh makes the control socket as its path plus a dot and 16 characters, then renames it.
        let middling = CanopyHome(path: "/var/folders/6r/0j694l0d2xvbrrz62zw7lg5c0000gn/T/cnp-hosts.Gl9OurnUOa/home")
        let tight = HostPaths.controlSocket(home: middling, homeID: "5ed625bf", alias: "hindie-box", uid: 501)
        #expect(tight.utf8.count + 17 < 104)
        #expect(
            HostPaths.remotePaneSocket(uid: 1000, homeID: "0123abcd", pane: "p7") == "/tmp/canopy-1000/0123abcd-p7.sock"
        )
    }
}

struct SSHCommandTests {
    let ssh = SSHCommand(executable: "/usr/bin/ssh", controlPath: "/c/sock", alias: "box")

    @Test func theMasterHoldsTheConnectionAndChecksTheServer() {
        let argv = ssh.master()

        #expect(argv.first == "/usr/bin/ssh")
        #expect(argv.last == "box")
        for option in ["ControlPersist=no", "ServerAliveInterval=15", "ServerAliveCountMax=3", "BatchMode=yes"] {
            #expect(argv.contains(option))
        }
        #expect(argv.contains("-M") && argv.contains("-N"))
        #expect(argv.containsSequence(["-S", "/c/sock"]))
    }

    @Test func commandsGoThroughTheMasterAndNeverBecomeOne() {
        let exec = ssh.exec(["git", "-C", "/a b", "status"])
        let attach = ssh.attach(["tmux", "attach"], forwards: [(remote: "/tmp/r.sock", local: "/l.sock")])

        for argv in [exec, attach] {
            #expect(argv.containsSequence(["-S", "/c/sock"]))
            #expect(argv.containsSequence(["-o", "ControlMaster=no"]))
            #expect(argv.containsSequence(["--", "box"]))
        }
        for argv in [exec, attach] {
            // A session the master refuses, as past sshd's MaxSessions, must not reach the host around it.
            #expect(argv.containsSequence(["-o", "ProxyCommand=/usr/bin/false"]))
            #expect(argv.containsSequence(["-o", "BatchMode=yes"]))
        }
        #expect(exec.last == "'git' '-C' '/a b' 'status'")
        #expect(!exec.contains("-t"))
        #expect(attach.contains("-t"))
        #expect(attach.containsSequence(["-o", "LogLevel=ERROR"]))
        #expect(attach.containsSequence(["-R", "/tmp/r.sock:/l.sock"]))
        #expect(ssh.control("check") == ["/usr/bin/ssh", "-S", "/c/sock", "-O", "check", "box"])
    }

    @Test func quotedWordsReachTheRemoteShellUnchanged() throws {
        let words = ["plain", "with space", "it's", "$HOME", "a\nb", "", "*", "`date`"]

        let result = try Subprocess.run(
            "/bin/sh", ["-c", "printf '%s\\0' " + SSHCommand.shellQuoted(words)], environment: [:], directory: nil,
            timeout: .seconds(10))

        let printed = String(decoding: result.stdout, as: UTF8.self).split(
            separator: "\0", omittingEmptySubsequences: false)
        #expect(printed.dropLast().map(String.init) == words)
    }

    @Test func canopySSHNamesAnotherSSHForTests() {
        #expect(SSHCommand.executable(environment: [:]) == "/usr/bin/ssh")
        #expect(SSHCommand.executable(environment: ["CANOPY_SSH": "/x/fake-ssh"]) == "/x/fake-ssh")
    }
}

extension Array where Element: Equatable {
    func containsSequence(_ part: [Element]) -> Bool {
        guard part.count <= count else { return false }
        return (0...(count - part.count)).contains { Array(self[$0..<($0 + part.count)]) == part }
    }
}
