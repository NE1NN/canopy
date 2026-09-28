# Canopy Ports Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show which ports each row's processes listen on, in a panel at the bottom of the sidebar and through `canopy ports`, and stop them with one click or command.

**Architecture:** `CanopyCore` reads every listening TCP socket of the user's processes with libproc, then gives each port to the row whose terminal started its process, or else the row whose folder the process works in.
Attribution is a pure function over a process table, so it is tested against a made-up one.
`RowLifecycle` joins the scan with the terminals' shell pids on the main actor, and serves both the control API and the app's panel, which scans every 2 seconds while the window can be seen.

**Tech Stack:** Swift 6.2, libproc (`proc_listpids`, `proc_pidinfo`, `proc_pidfdinfo`), SwiftUI, swift-argument-parser, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-27-canopy-design.md`, "Ports", `canopy ports` under "Commands", and the ports panel line under "Persistence".

## Global Constraints

- Scan every 2 seconds while the window is visible, and on demand for the CLI, with libproc rather than `lsof`.
- Only TCP sockets in the listening state owned by the current user. IPv4 and IPv6 sockets on the same port and process count as one port.
- A port belongs to at most one row: the row whose pane shell its process descends from, otherwise the row whose folder the process works in, the deepest when folders nest, otherwise none.
- The panel groups ports under their row's branch name in sidebar order, with ports sorted by number, and badges wrap.
- Clicking a branch heading selects the row. Clicking a badge opens `http://localhost:<port>`. Hovering a badge shows the process name and PID.
- A badge's `x` stops its process and its tooltip names the process. A group's `x` stops every process holding a port in that row.
- Stopping sends SIGTERM, then SIGKILL if the port is still listening after 3 seconds.
- Whether the panel is collapsed is saved in `state.json`.
- Never block a Swift concurrency thread: scans run on a dispatch queue.

## Review Focus

1. **A server started in a row's terminal that works in another folder** must still count as that row's. Pinned by `aProcessStartedInARowsTerminalBelongsToThatRow` in Task 2 and `portsAnswerOverTheSocket` in Task 4.
2. **A folder that only shares a prefix with a row**, like `feat-2` next to `feat`, must not count as inside it. Pinned by `portsOutsideEveryRowAreLeftOut` in Task 2.
3. **A process that ignores SIGTERM** must still be stopped. Pinned by `killsAProcessThatIgnoresSIGTERM` in Task 3.
4. **An agent stopping a port no row owns**, such as the user's database, must be refused. Pinned by the `port_not_found` check in `portsAnswerOverTheSocket` in Task 4.
5. **A server listening on IPv4 and IPv6 at once** must show one badge. Pinned by `findsAPortOnceAcrossIPv4AndIPv6` in Task 1.

---

## Task 1: List listening TCP ports with libproc

**Files:** Create `Sources/CanopyCore/Ports/PortScanner.swift`, `Sources/CanopyCore/Ports/ProcessTable.swift`. Modify `PtyProcess.swift` and `Pane.swift`, which now read folders and names through `ProcessTable`. Test `Tests/CanopyCoreTests/PortScannerTests.swift`.

**Interfaces:** Produces `ListeningPort` (`port: UInt16`, `pid`, `process`), `PortScanner.listeningPorts(uid:) -> [ListeningPort]`, and `ProcessTable.parent(of:)`, `folder(of:)`, and `name(of:)`.

The scanner lists the user's pids with `proc_listpids(PROC_UID_ONLY)`, their descriptors with `PROC_PIDLISTFDS`, and each socket with `PROC_PIDFDSOCKETINFO`, keeping TCP sockets in `TSI_S_LISTEN`.
The local port comes back in network byte order.
A scan of 815 processes takes about 4 ms, so every 2 seconds is cheap.

- [ ] **Step 1: Write the failing tests**

The tests listen from the test process itself, on IPv4 and IPv6 at the same port, and start a child with Foundation's `Process` to read its parent and folder.

`Tests/CanopyCoreTests/PortScannerTests.swift` (new):

```swift
import Foundation
import Testing

@testable import CanopyCore

/// A TCP socket listening on loopback, closed when released.
final class Listener {
    let fd: Int32
    let port: UInt16

    init(family: Int32 = AF_INET, port: UInt16 = 0) throws {
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var bound: Int32
        if family == AF_INET6 {
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &yes, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in6()
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = port.bigEndian
            address.sin6_addr = in6addr_loopback
            bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = UInt32(0x7f00_0001).bigEndian
            bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard bound == 0, listen(fd, 5) == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        var address = sockaddr_in6()
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &length) }
        }
        self.fd = fd
        // sin_port and sin6_port sit at the same offset.
        self.port = UInt16(bigEndian: address.sin6_port)
    }

    deinit {
        close(fd)
    }
}

struct PortScannerTests {
    func mine(_ port: UInt16) -> [ListeningPort] {
        PortScanner.listeningPorts().filter { $0.pid == getpid() && $0.port == port }
    }

    @Test func findsAPortOnceAcrossIPv4AndIPv6() throws {
        let v4 = try Listener(family: AF_INET)
        let v6 = try Listener(family: AF_INET6, port: v4.port)

        let found = mine(v4.port)

        #expect(found.count == 1)
        #expect(found.first?.process == ProcessTable.name(of: getpid()))
        _ = v6
    }

    @Test func connectionsAndClosedListenersAreNotListed() throws {
        var listener: Listener? = try Listener()
        let port = try #require(listener?.port)
        let client = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(client) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = UInt32(0x7f00_0001).bigEndian
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(connected == 0)
        #expect(mine(port).count == 1)

        listener = nil

        #expect(mine(port).isEmpty)
    }
}

struct ProcessTableTests {
    @Test func readsAChildsParentFolderAndName() throws {
        let dir = try TempDir()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        child.currentDirectoryURL = URL(fileURLWithPath: dir.path)
        try child.run()
        defer { child.terminate() }

        #expect(ProcessTable.parent(of: child.processIdentifier) == getpid())
        #expect(ProcessTable.folder(of: child.processIdentifier) == dir.path)
        #expect(ProcessTable.name(of: child.processIdentifier) == "sleep")
        #expect(ProcessTable.parent(of: 999_999) == nil)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter 'PortScannerTests|ProcessTableTests'`
Expected: does not compile, `PortScanner`, `ListeningPort`, and `ProcessTable` are missing.

- [ ] **Step 3: Implement**

`Sources/CanopyCore/Ports/PortScanner.swift` (new):

```swift
import Darwin

/// A TCP port a process listens on.
public struct ListeningPort: Sendable, Equatable, Hashable, Codable {
    public var port: UInt16
    public var pid: pid_t
    public var process: String

    public init(port: UInt16, pid: pid_t, process: String) {
        self.port = port
        self.pid = pid
        self.process = process
    }
}

public enum PortScanner {
    /// Every TCP port in the listening state held by one user's processes, read with libproc rather than `lsof`.
    /// A process listening on both IPv4 and IPv6 for a port counts once. Makes a few system calls per process, so
    /// call it off the Swift concurrency pool.
    public static func listeningPorts(uid: uid_t = getuid()) -> [ListeningPort] {
        var found = Set<ListeningPort>()
        for pid in processes(of: uid) {
            for port in listeningPorts(of: pid) {
                found.insert(ListeningPort(port: port, pid: pid, process: ProcessTable.name(of: pid) ?? "pid \(pid)"))
            }
        }
        return found.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }

    static func processes(of uid: uid_t) -> [pid_t] {
        let bytes = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
        guard bytes > 0 else { return [] }
        // Room for processes started between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size + 64)
        let filled = proc_listpids(
            UInt32(PROC_UID_ONLY), uid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        return pids.prefix(Int(filled) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }

    static func listeningPorts(of pid: pid_t) -> Set<UInt16> {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, Int32(descriptors.count * stride))
        guard filled > 0 else { return [] }
        var ports = Set<UInt16>()
        for descriptor in descriptors.prefix(Int(filled) / stride)
        where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                info.psi.soi_kind == SOCKINFO_TCP,
                info.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN
            else { continue }
            let port = UInt16(truncatingIfNeeded: info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport)
            ports.insert(UInt16(bigEndian: port))
        }
        return ports
    }
}
```

`Sources/CanopyCore/Ports/ProcessTable.swift` (new):

```swift
import Darwin

/// Facts about a running process, read from the kernel.
public enum ProcessTable {
    public static func parent(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    /// The process's working folder.
    public static func folder(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    public static func name(of pid: pid_t) -> String? {
        var name = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &name, UInt32(name.count)) > 0 else { return nil }
        return name.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
}
```

`Sources/CanopyCore/Terminal/Pane.swift` (modify):

```diff
--- a/Sources/CanopyCore/Terminal/Pane.swift
+++ b/Sources/CanopyCore/Terminal/Pane.swift
@@ -118,7 +118,7 @@ public final class Pane: Identifiable {
 
     /// The shell's working folder now, so a `cd` is remembered across relaunches.
     public var currentDirectory: String? {
-        process.flatMap { PtyProcess.currentDirectory(of: $0.pid) }
+        process.flatMap { ProcessTable.folder(of: $0.pid) }
     }
 
     /// The folder it was restored into, or the row's folder, or the home folder if both are gone.
```

`Sources/CanopyCore/Terminal/PtyProcess.swift` (modify):

```diff
--- a/Sources/CanopyCore/Terminal/PtyProcess.swift
+++ b/Sources/CanopyCore/Terminal/PtyProcess.swift
@@ -137,10 +137,8 @@ public final class PtyProcess: @unchecked Sendable {
     /// The process group the terminal is running in the foreground, such as `claude` or the shell itself.
     public var foreground: ForegroundProcess? {
         let group = state.withLock { $0.fd >= 0 ? tcgetpgrp($0.fd) : -1 }
-        guard group > 0 else { return nil }
-        var name = [CChar](repeating: 0, count: 256)
-        guard proc_name(group, &name, UInt32(name.count)) > 0 else { return nil }
-        return ForegroundProcess(pid: group, name: name.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
+        guard group > 0, let name = ProcessTable.name(of: group) else { return nil }
+        return ForegroundProcess(pid: group, name: name)
     }
 
     /// True while the process itself is in the foreground with its line editor waiting for input.
@@ -268,17 +266,6 @@ public final class PtyProcess: @unchecked Sendable {
         readSource = nil
     }
 
-    /// The working folder of a process, read from the kernel.
-    public static func currentDirectory(of pid: pid_t) -> String? {
-        var info = proc_vnodepathinfo()
-        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
-        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
-        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
-            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
-        }
-        return path.isEmpty ? nil : path
-    }
-
     static func exitCode(fromWaitStatus status: Int32) -> Int32 {
         let signal = status & 0x7f
         return signal == 0 ? (status >> 8) & 0xff : 128 + signal
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `make lint && make test`. Expected: every test passes.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "feat: list listening TCP ports with libproc"
```

## Task 2: Give each listening port to the row that started it

**Files:** Create `Sources/CanopyCore/Ports/PortAttribution.swift`. Test `Tests/CanopyCoreTests/PortAttributionTests.swift`.

**Interfaces:**
- Consumes `ListeningPort` from Task 1.
- Produces `PortGroup` (`rowPath`, `ports`) and `PortAttribution.assign(_:rows:shells:parent:folder:) -> [PortGroup]`, where `rows` are row folders in sidebar order and `shells` maps a row folder to its pane shell pids.

The ancestor walk stops at pid 1 and at any pid it has seen, so a bad process table cannot loop it.
Folders match with `Paths.isInside`, which needs a `/` after the row folder, so `feat-2` is not inside `feat`.

- [ ] **Step 1: Write the failing tests**

`Tests/CanopyCoreTests/PortAttributionTests.swift` (new):

```swift
import Foundation
import Testing

@testable import CanopyCore

/// A made-up process tree: each pid's parent and working folder.
struct FakeProcesses {
    var parents: [pid_t: pid_t] = [:]
    var folders: [pid_t: String] = [:]

    func assign(_ ports: [ListeningPort], rows: [String], shells: [String: [pid_t]] = [:]) -> [PortGroup] {
        PortAttribution.assign(
            ports, rows: rows, shells: shells, parent: { parents[$0] }, folder: { folders[$0] })
    }
}

struct PortAttributionTests {
    func port(_ number: UInt16, _ pid: pid_t) -> ListeningPort {
        ListeningPort(port: number, pid: pid, process: "p\(pid)")
    }

    @Test func aProcessStartedInARowsTerminalBelongsToThatRow() {
        // node (300) runs under bun (200) under row a's shell (100), but works in row b's folder.
        let table = FakeProcesses(parents: [300: 200, 200: 100, 100: 1], folders: [300: "/w/b/web"])

        let groups = table.assign([port(3000, 300)], rows: ["/w/a", "/w/b"], shells: ["/w/a": [100]])

        #expect(groups == [PortGroup(rowPath: "/w/a", ports: [port(3000, 300)])])
    }

    @Test func aShellListeningItselfBelongsToItsRow() {
        let table = FakeProcesses(parents: [100: 1])

        let groups = table.assign([port(8080, 100)], rows: ["/w/a"], shells: ["/w/a": [100]])

        #expect(groups.map(\.rowPath) == ["/w/a"])
    }

    @Test func otherwiseTheDeepestRowFolderWins() {
        let table = FakeProcesses(
            parents: [500: 1, 501: 1, 502: 1],
            folders: [500: "/r/main/.claude/worktrees/x/web", 501: "/r/main/src", 502: "/r/main"])

        let groups = table.assign(
            [port(4000, 500), port(4001, 501), port(4002, 502)], rows: ["/r/main", "/r/main/.claude/worktrees/x"])

        #expect(
            groups == [
                PortGroup(rowPath: "/r/main", ports: [port(4001, 501), port(4002, 502)]),
                PortGroup(rowPath: "/r/main/.claude/worktrees/x", ports: [port(4000, 500)]),
            ])
    }

    @Test func portsOutsideEveryRowAreLeftOut() {
        // A folder that only shares a prefix with a row is not inside it.
        let table = FakeProcesses(parents: [600: 1, 601: 1], folders: [600: "/elsewhere", 601: "/w/feat-2"])

        #expect(table.assign([port(5432, 600), port(3000, 601), port(9, 602)], rows: ["/w/feat"]).isEmpty)
    }

    @Test func groupsFollowRowOrderAndPortsSortByNumber() {
        let table = FakeProcesses(parents: [700: 1, 701: 1], folders: [700: "/w/b", 701: "/w/a"])

        let groups = table.assign([port(3001, 700), port(3000, 700), port(4173, 701)], rows: ["/w/a", "/w/b"])

        #expect(groups.map(\.rowPath) == ["/w/a", "/w/b"])
        #expect(groups.last?.ports.map(\.port) == [3000, 3001])
    }

    @Test func aLoopInTheParentsEnds() {
        let table = FakeProcesses(parents: [5: 6, 6: 5], folders: [5: "/w/a"])

        #expect(table.assign([port(3000, 5)], rows: ["/w/a"]).map(\.rowPath) == ["/w/a"])
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter PortAttributionTests`
Expected: does not compile, `PortGroup` and `PortAttribution` are missing.

- [ ] **Step 3: Implement**

`Sources/CanopyCore/Ports/PortAttribution.swift` (new):

```swift
import Darwin

/// A row's ports, sorted by number.
public struct PortGroup: Sendable, Equatable {
    public var rowPath: String
    public var ports: [ListeningPort]

    public init(rowPath: String, ports: [ListeningPort]) {
        self.rowPath = rowPath
        self.ports = ports
    }
}

public enum PortAttribution {
    /// Gives each port to at most one row: the row whose terminal started its process, else the row whose folder
    /// the process works in, the deepest when row folders nest. Ports of neither are left out. `rows` are row
    /// folders in sidebar order, which the groups keep, and `shells` holds each row's terminal shell pids.
    public static func assign(
        _ ports: [ListeningPort], rows: [String], shells: [String: [pid_t]],
        parent: (pid_t) -> pid_t?, folder: (pid_t) -> String?
    ) -> [PortGroup] {
        var rowOfShell: [pid_t: String] = [:]
        for (row, pids) in shells {
            for pid in pids { rowOfShell[pid] = row }
        }
        var byRow: [String: [ListeningPort]] = [:]
        for port in ports {
            let row =
                startingRow(of: port.pid, rowOfShell: rowOfShell, parent: parent)
                ?? folder(port.pid).flatMap { folder in
                    rows.filter { Paths.isInside(folder, $0) }.max { $0.count < $1.count }
                }
            if let row { byRow[row, default: []].append(port) }
        }
        return rows.compactMap { row in
            byRow[row].map { PortGroup(rowPath: row, ports: $0.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }) }
        }
    }

    /// The row of the nearest terminal shell among the process and its ancestors.
    private static func startingRow(
        of pid: pid_t, rowOfShell: [pid_t: String], parent: (pid_t) -> pid_t?
    ) -> String? {
        var current = pid
        var seen: Set<pid_t> = []
        while current > 1, seen.insert(current).inserted {
            if let row = rowOfShell[current] { return row }
            guard let next = parent(current) else { return nil }
            current = next
        }
        return nil
    }
}
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `make lint && make test`. Expected: every test passes.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "feat: give each listening port to the row that started it"
```

## Task 3: Stop a port's process, forcefully if it holds on

**Files:** Create `Sources/CanopyCore/Ports/PortStopper.swift`. Test `Tests/CanopyCoreTests/PortStopperTests.swift`.

**Interfaces:** Produces `PortStopper(grace:scan:)` and `stop(_ ports: [ListeningPort]) async -> Outcome`, where `Outcome.killed` lists the pids that needed SIGKILL.

The stopper signals the listening process itself, as the spec says, and rescans every 100 ms until it lets go of its ports or the grace period ends.
It never signals Canopy or launchd.
The tests use perl, which macOS ships, as a listener that holds a free port until it exits, and one that ignores SIGTERM.

- [ ] **Step 1: Write the failing tests**

`Tests/CanopyCoreTests/PortStopperTests.swift` (new):

```swift
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
```

- [ ] **Step 2: Run them to see them fail**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter PortStopperTests`
Expected: does not compile, `PortStopper` is missing.

- [ ] **Step 3: Implement**

`Sources/CanopyCore/Ports/PortStopper.swift` (new):

```swift
import Foundation

/// Stops the processes listening on ports: SIGTERM first, then SIGKILL for any still listening after a grace period.
public struct PortStopper: Sendable {
    public var grace: Duration
    private let scan: @Sendable () -> [ListeningPort]

    public init(
        grace: Duration = .seconds(3),
        scan: @escaping @Sendable () -> [ListeningPort] = { PortScanner.listeningPorts() }
    ) {
        self.grace = grace
        self.scan = scan
    }

    public struct Outcome: Sendable, Equatable {
        /// Processes that were still listening after the grace period and got SIGKILL.
        public var killed: [pid_t]
    }

    /// Returns once every process has let go of its ports, or has been killed. Canopy itself and launchd are never
    /// signalled.
    public func stop(_ ports: [ListeningPort]) async -> Outcome {
        let targets = ports.filter { $0.pid > 1 && $0.pid != getpid() }
        for pid in Set(targets.map(\.pid)) {
            kill(pid, SIGTERM)
        }
        let deadline = ContinuousClock.now + grace
        var holding = await stillListening(targets)
        while !holding.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            holding = await stillListening(targets)
        }
        let killed = Set(holding.map(\.pid)).sorted()
        for pid in killed {
            kill(pid, SIGKILL)
        }
        return Outcome(killed: killed)
    }

    private func stillListening(_ targets: [ListeningPort]) async -> [ListeningPort] {
        let scan = scan
        let listening = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: Set(scan().map { PortKey($0) })) }
        }
        return targets.filter { listening.contains(PortKey($0)) }
    }

    private struct PortKey: Hashable {
        var port: UInt16
        var pid: pid_t

        init(_ port: ListeningPort) {
            self.port = port.port
            self.pid = port.pid
        }
    }
}
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `make lint && make test`. Expected: every test passes.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "feat: stop a port's process, forcefully if it holds on"
```

## Task 4: `canopy ports`

**Files:** Create `Sources/CanopyCore/Control/PortMethods.swift`, `Sources/CanopyCore/Rows/RowLifecycle+Ports.swift`, `Sources/CanopyCLI/PortsCommand.swift`. Modify `WorkspaceControlHandler.swift`, `WorkspaceError.swift`, `CanopyCLI.swift`, `AgentGuide.swift`, `scripts/e2e.sh`. Test `ControlServerTests.swift`, `ControlProtocolTests.swift`.

**Interfaces:**
- Consumes Tasks 1 to 3.
- Produces `PortMethod.list` (`"ports.list"`) and `PortMethod.stop` (`"ports.stop"`), `PortInfo` (`repo`, `row`, `rowPath`, `port`, `pid`, `process`), `PortsListParams(target:all:)`, `PortsStopParams(port:)`, `PortsStopResult` (`port`, `stopped`, `killed`), and the error `port_not_found`.
- Produces `RowLifecycle.portGroups()`, `portInfo(rowPath:)`, and `stopPort(_:)`.

`ports.list` resolves its row the way `term.list` does, and lists every row's ports with `--all` or when no row resolves.
`ports.stop` only stops a port that belongs to a row.
Canopy manages its rows' processes, and a port number from an agent should never reach something like the user's database.

- [ ] **Step 1: Write the failing tests**

The socket test starts one listener in the main row's terminal after `cd /`, so only the terminal ties it to the row, and one outside Canopy in the feature row's folder.

`Tests/CanopyCoreTests/ControlProtocolTests.swift` (modify):

```diff
--- a/Tests/CanopyCoreTests/ControlProtocolTests.swift
+++ b/Tests/CanopyCoreTests/ControlProtocolTests.swift
@@ -24,6 +24,8 @@ struct JSONValueTests {
         #expect(try JSONValue.object([:]).decode(RowListParams.self).all == false)
         #expect(try JSONValue.object([:]).decode(RowRefParams.self).target == TargetHint())
         #expect(try JSONValue.object([:]).decode(PRShowParams.self).refresh == false)
+        #expect(try JSONValue.object([:]).decode(PortsListParams.self).all == false)
+        #expect(throws: DecodingError.self) { try JSONValue.object([:]).decode(PortsStopParams.self) }
         #expect(throws: DecodingError.self) { try JSONValue.object([:]).decode(RowNewParams.self) }
     }
```

`Tests/CanopyCoreTests/ControlServerTests.swift` (modify):

```diff
--- a/Tests/CanopyCoreTests/ControlServerTests.swift
+++ b/Tests/CanopyCoreTests/ControlServerTests.swift
@@ -222,6 +222,56 @@ struct ControlServerTests {
         #expect(main.error?.code == "no_pr_lookup")
     }
 
+    @Test func portsAnswerOverTheSocket() async throws {
+        let dir = try TempDir()
+        let repo = try await Fixture.repo(in: dir)
+        let feature = dir.sub("home/worktrees/demo/feat-web")
+        try await Fixture.worktree(repo: repo, branch: "feat/web", at: feature)
+        let (_, server, client, _) = try await startServer(dir)
+        defer { server.stop() }
+        _ = try await call(client, ControlMethod.repoAdd, RepoAddParams(path: repo), as: RepoInfo.self)
+        // Started in the main row's terminal but working in /, so only the terminal ties it to the row.
+        let listener =
+            #"cd / && perl -MIO::Socket::INET -e 'my $s = IO::Socket::INET->new(Listen => 5, LocalAddr => "127.0.0.1", LocalPort => 0) or die; sleep 120'"#
+        let pane = try await call(
+            client, TermMethod.new, TermNewParams(target: TargetHint(repo: "demo", row: "main"), run: listener),
+            as: TermNewResult.self)
+        // Started outside Canopy, in the feature row's folder.
+        let outside = try await ListeningChild.start(in: feature)
+        defer { outside.process.terminate() }
+
+        var all: [PortInfo] = []
+        #expect(
+            await eventually {
+                all = (try? await call(client, PortMethod.list, PortsListParams(all: true), as: [PortInfo].self)) ?? []
+                return all.count == 2
+            })
+        #expect(all.map(\.row) == ["main", "feat/web"])
+        #expect(all.first?.process == "perl")
+        #expect(all.last?.port == Int(outside.port.port))
+        let featureOnly = try await call(
+            client, PortMethod.list, PortsListParams(target: TargetHint(repo: "demo", row: "feat/web")),
+            as: [PortInfo].self)
+        #expect(featureOnly.map(\.pid) == [outside.port.pid])
+
+        let stopped = try await call(
+            client, PortMethod.stop, PortsStopParams(port: Int(outside.port.port)), as: PortsStopResult.self)
+
+        #expect(stopped.stopped.map(\.pid) == [outside.port.pid])
+        #expect(stopped.killed.isEmpty)
+        #expect(await eventually { !outside.process.isRunning })
+        // This test process listens too, but its folder is no row's, so the port is not Canopy's to stop.
+        let stranger = try Listener()
+        let strangerPort = Int(stranger.port)
+        let refused = try await offPool {
+            try client.send(
+                ControlRequest(method: PortMethod.stop, params: try .from(PortsStopParams(port: strangerPort))))
+        }
+        #expect(refused.error?.code == "port_not_found")
+        _ = stranger
+        _ = try await call(client, TermMethod.close, TermCloseParams(pane: pane.pane, force: true), as: JSONValue.self)
+    }
+
     @Test func errorsCarryCodes() async throws {
         let dir = try TempDir()
         let (_, server, client, _) = try await startServer(dir)
```

- [ ] **Step 2: Run them to see them fail**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter 'portsAnswerOverTheSocket|ControlProtocolTests'`
Expected: does not compile, `PortMethod`, `PortInfo`, and the params are missing.

- [ ] **Step 3: Implement**

The e2e step runs a perl listener in a row's terminal, finds it with `canopy ports`, and stops it with `canopy ports stop`.

`Sources/CanopyCLI/AgentGuide.swift` (modify):

```diff
--- a/Sources/CanopyCLI/AgentGuide.swift
+++ b/Sources/CanopyCLI/AgentGuide.swift
@@ -45,6 +45,14 @@ struct AgentGuide: ParsableCommand {
 
         Terminal IDs such as p12 stay unique across relaunches. `term send`, `read`, and `close` never start Canopy.
 
+        ## Ports
+
+            canopy ports [--all]                          what the row's processes listen on, or every row's
+            canopy ports stop <port>                      SIGTERM, then SIGKILL after 3 seconds if still listening
+
+        A port belongs to the row whose terminal started its process, otherwise to the row whose folder the process
+        works in. `ports stop` only stops ports that belong to a row.
+
         ## Pull requests
 
             canopy pr [<branch>] [--refresh]              the row's PR: number, state, title, and URL
```

`Sources/CanopyCLI/CanopyCLI.swift` (modify):

```diff
--- a/Sources/CanopyCLI/CanopyCLI.swift
+++ b/Sources/CanopyCLI/CanopyCLI.swift
@@ -9,7 +9,8 @@ struct CanopyCLI: AsyncParsableCommand {
         abstract: "Drive Canopy from the command line.",
         version: CanopyVersion.current,
         subcommands: [
-            Status.self, RepoCommand.self, RowCommand.self, TermCommand.self, PRCommand.self, AgentGuide.self,
+            Status.self, RepoCommand.self, RowCommand.self, TermCommand.self, PortsCommand.self, PRCommand.self,
+            AgentGuide.self,
         ]
     )
 }
```

`Sources/CanopyCLI/PortsCommand.swift` (new):

```swift
import ArgumentParser
import CanopyCore

struct PortsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ports",
        abstract: "List and stop the ports your rows' processes listen on.",
        discussion: """
            A port belongs to the row whose terminal started its process, otherwise to the row whose folder the \
            process works in. Ports that belong to no row are not listed and cannot be stopped from here.
            """,
        subcommands: [List.self, Stop.self],
        defaultSubcommand: List.self
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List the ports of the row you are in, or of every row.")

        @OptionGroup var rowOptions: TermCommand.RowOptions
        @Flag(help: "List ports in every row.")
        var all = false
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(PortMethod.list, PortsListParams(target: rowOptions.hint, all: all))
            try client.print(result) {
                let ports = try result.decode([PortInfo].self)
                guard !ports.isEmpty else { return "No ports." }
                return Table.render(
                    ["PORT", "PROCESS", "PID", "REPO", "ROW"],
                    ports.map { ["\($0.port)", $0.process, "\($0.pid)", $0.repo, $0.row] }
                )
            }
        }
    }

    struct Stop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Stop the process listening on a port.",
            discussion: """
                Sends SIGTERM, then SIGKILL if the port is still listening after 3 seconds. Any other ports the \
                process holds close too.
                """
        )

        @Argument(help: "The port, for example 3000.")
        var port: Int
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(PortMethod.stop, PortsStopParams(port: port))
            try client.print(result) {
                let stopped = try result.decode(PortsStopResult.self)
                return stopped.stopped.map { info in
                    let how = stopped.killed.contains(info.pid) ? " It ignored SIGTERM, so it was killed." : ""
                    return "Stopped \(info.process) (pid \(info.pid)) on port \(info.port).\(how)"
                }
                .joined(separator: "\n")
            }
        }
    }
}
```

`Sources/CanopyCore/Control/PortMethods.swift` (new):

```swift
public enum PortMethod {
    public static let list = "ports.list"
    public static let stop = "ports.stop"
}

/// One port as `canopy ports` shows it.
public struct PortInfo: Codable, Sendable, Equatable {
    public var repo: String
    public var row: String
    public var rowPath: String
    public var port: Int
    public var pid: Int32
    public var process: String
}

public struct PortsListParams: Codable, Sendable {
    public var target: TargetHint
    /// Every row's ports, as when no row resolves.
    public var all: Bool

    public init(target: TargetHint = TargetHint(), all: Bool = false) {
        self.target = target
        self.all = all
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decodeIfPresent(TargetHint.self, forKey: .target) ?? TargetHint()
        all = try container.decodeIfPresent(Bool.self, forKey: .all) ?? false
    }
}

public struct PortsStopParams: Codable, Sendable {
    public var port: Int

    public init(port: Int) {
        self.port = port
    }
}

public struct PortsStopResult: Codable, Sendable {
    public var port: Int
    public var stopped: [PortInfo]
    /// Processes that ignored SIGTERM and were killed.
    public var killed: [Int32]
}
```

`Sources/CanopyCore/Control/WorkspaceControlHandler.swift` (modify):

```diff
--- a/Sources/CanopyCore/Control/WorkspaceControlHandler.swift
+++ b/Sources/CanopyCore/Control/WorkspaceControlHandler.swift
@@ -112,6 +112,22 @@ public struct WorkspaceControlHandler: Sendable {
                     repo: snapshot.repo(path: row.repoPath)?.name ?? "", branch: row.displayName, path: row.path,
                     pr: pr))
 
+        case PortMethod.list:
+            let params = try request.decodeParams(PortsListParams.self)
+            // Every row's ports with --all, or when no row resolves.
+            var row: Row?
+            if !params.all {
+                do {
+                    row = try TargetResolver.row(for: params.target, in: await workspace.snapshot)
+                } catch WorkspaceError.missingTarget {
+                    row = nil
+                }
+            }
+            return try .from(await rows.portInfo(rowPath: row?.path))
+
+        case PortMethod.stop:
+            return try .from(try await rows.stopPort(request.decodeParams(PortsStopParams.self).port))
+
         case TermMethod.list:
             let params = try request.decodeParams(TermListParams.self)
             let snapshot = await workspace.snapshot
```

`Sources/CanopyCore/Rows/RowLifecycle+Ports.swift` (new):

```swift
import Foundation

/// Ports for the panel and `canopy ports`, on the main actor where the terminals' shells are known.
extension RowLifecycle {
    /// Every row's ports, in sidebar order: each repo's rows, then its other worktrees.
    public func portGroups() async -> [PortGroup] {
        let rows = await workspace.snapshot.repos.flatMap(\.allRows).map(\.path)
        let shells = terminals.tabsByRow.mapValues { tabs in tabs.flatMap(\.paneList).compactMap(\.pid) }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(
                    returning: PortAttribution.assign(
                        PortScanner.listeningPorts(), rows: rows, shells: shells, parent: ProcessTable.parent(of:),
                        folder: ProcessTable.folder(of:)))
            }
        }
    }

    /// One row's ports, or every row's when `rowPath` is nil.
    public func portInfo(rowPath: String?) async -> [PortInfo] {
        let groups = await portGroups()
        let snapshot = await workspace.snapshot
        return groups.filter { rowPath == nil || $0.rowPath == rowPath }.flatMap { group in
            let row = snapshot.row(path: group.rowPath)
            let repo = row.flatMap { snapshot.repo(path: $0.repoPath)?.name } ?? ""
            return group.ports.map { port in
                PortInfo(
                    repo: repo, row: row?.displayName ?? group.rowPath, rowPath: group.rowPath, port: Int(port.port),
                    pid: port.pid, process: port.process)
            }
        }
    }

    /// Stops what listens on a port, if the port belongs to a row. Anything else is not Canopy's to stop.
    public func stopPort(_ number: Int) async throws -> PortsStopResult {
        let holding = await portInfo(rowPath: nil).filter { $0.port == number }
        guard !holding.isEmpty else { throw WorkspaceError.portNotFound(number) }
        let outcome = await PortStopper().stop(
            holding.map { ListeningPort(port: UInt16($0.port), pid: $0.pid, process: $0.process) })
        return PortsStopResult(port: number, stopped: holding, killed: outcome.killed)
    }

}
```

`Sources/CanopyCore/Workspace/WorkspaceError.swift` (modify):

```diff
--- a/Sources/CanopyCore/Workspace/WorkspaceError.swift
+++ b/Sources/CanopyCore/Workspace/WorkspaceError.swift
@@ -24,6 +24,7 @@ public enum WorkspaceError: Error, Sendable, Equatable {
     case notOnGitHub(String)
     case ghUnavailable(String)
     case ghFailed(String)
+    case portNotFound(Int)
     case git(GitError)
 
     public var code: String {
@@ -53,6 +54,7 @@ public enum WorkspaceError: Error, Sendable, Equatable {
         case .notOnGitHub: "not_github"
         case .ghUnavailable: "gh_unavailable"
         case .ghFailed: "gh_failed"
+        case .portNotFound: "port_not_found"
         case .git: "git_failed"
         }
     }
@@ -87,6 +89,8 @@ public enum WorkspaceError: Error, Sendable, Equatable {
         case .notOnGitHub(let repo): "\(repo)'s origin is not on GitHub, so its rows have no PRs."
         case .ghUnavailable(let warning): warning
         case .ghFailed(let message): "Pull requests did not load: \(message)"
+        case .portNotFound(let port):
+            "No row's process listens on port \(port). Run `canopy ports --all`; Canopy only stops its rows' ports."
         case .git(let error): error.description
         }
     }
```

`scripts/e2e.sh` (modify):

```diff
--- a/scripts/e2e.sh
+++ b/scripts/e2e.sh
@@ -166,6 +166,24 @@ wait_for_text sent-text || fail "term send did not reach the terminal"
 if "$cli" term list --all --json | grep -q "\"$pane\""; then fail "closed terminal is still listed"; fi
 "$cli" agent-guide | grep -q "canopy term read" || fail "agent-guide is missing term read"
 
+step "canopy ports lists a server started in a row's terminal, and stops it"
+listen='my $s = IO::Socket::INET->new(Listen => 5, LocalAddr => "127.0.0.1", LocalPort => 0) or die; sleep 300'
+server=$("$cli" term new --repo demo --row feat/term --run "cd / && perl -MIO::Socket::INET -e '$listen'" --json |
+    /usr/bin/python3 -c 'import json, sys; print(json.load(sys.stdin)["pane"])')
+port=""
+for _ in $(seq 1 100); do
+    port=$("$cli" ports --repo demo --row feat/term --json |
+        /usr/bin/python3 -c 'import json, sys; ports = json.load(sys.stdin); print(ports[0]["port"] if ports else "")')
+    [[ -n "$port" ]] && break
+    sleep 0.1
+done
+[[ -n "$port" ]] || fail "canopy ports did not list the server"
+"$cli" ports --all | grep -q "^$port " || fail "ports --all is missing $port"
+"$cli" ports stop "$port" | grep -q "Stopped perl" || fail "ports stop did not stop the server"
+if "$cli" ports --all --json | grep -q "\"port\" : $port,"; then fail "port $port is still listed"; fi
+"$cli" term close "$server" >/dev/null
+"$cli" agent-guide | grep -q "canopy ports stop" || fail "agent-guide is missing ports"
+
 step "canopy pr says when a repo's origin is not on GitHub"
 if "$cli" pr feat/term --repo demo --json > "$work/pr-local.json" 2>/dev/null; then fail "expected failure"; fi
 grep -q '"not_github"' "$work/pr-local.json" || fail "missing not_github"
```

- [ ] **Step 4: Run everything**

Run: `make lint && make test && make e2e`
Expected: `e2e passed`, including "canopy ports lists a server started in a row's terminal, and stops it".

- [ ] **Step 5: Commit**

```bash
git add Sources Tests scripts
git commit -m "feat: canopy ports lists and stops a row's ports"
```

## Task 5: The ports panel

**Files:** Create `Sources/CanopyApp/Sidebar/PortsPanel.swift`. Modify `AppState.swift`, `Workspace.swift`, `AppModel.swift`, `SidebarView.swift`. Test `WorkspaceTests.swift`.

**Interfaces:** Consumes `RowLifecycle.portGroups()` and `PortStopper` from earlier tasks. Produces `AppState.portsCollapsed`, `Workspace.portsCollapsed`, and `setPortsCollapsed(_:)`.

Design choices, checked with window screenshots in dark and light mode, with 5, 30, and 61 ports, collapsed, and empty:
- The panel sits between the rows and Add Repo, with a divider on each side, and its header matches the sidebar's small uppercase labels.
- It grows with its groups up to 220 points, then scrolls, so many ports never squeeze the rows away.
- Collapsed, the header shows how many ports there are.
- Badges being stopped dim until their process lets go, since that can take 3 seconds.
- The app scans only while `NSApp.occlusionState` says some of it can be seen.
- Numbers use `Text(verbatim:)`. SwiftUI formats an integer interpolated into a `Text` literal for the locale, so port 3000 would read "3,000"; the PR badge had the same bug.

- [ ] **Step 1: Write the failing test**

`Tests/CanopyCoreTests/WorkspaceTests.swift` (modify):

```diff
--- a/Tests/CanopyCoreTests/WorkspaceTests.swift
+++ b/Tests/CanopyCoreTests/WorkspaceTests.swift
@@ -10,6 +10,17 @@ struct WorkspaceTests {
         return workspace
     }
 
+    @Test func thePortsPanelRemembersBeingCollapsed() async throws {
+        let dir = try TempDir()
+        let first = try await makeWorkspace(dir)
+        #expect(await first.portsCollapsed == false)
+
+        try await first.setPortsCollapsed(true)
+        await first.stop()
+
+        #expect(try await makeWorkspace(dir).portsCollapsed)
+    }
+
     @Test func addRepoShowsMainRow() async throws {
         let dir = try TempDir()
         let repo = try await Fixture.repo(in: dir)
```

- [ ] **Step 2: Run it to see it fail**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter thePortsPanelRemembersBeingCollapsed`
Expected: does not compile, `portsCollapsed` is missing.

- [ ] **Step 3: Implement**

`Sources/CanopyApp/AppModel.swift` (modify):

```diff
--- a/Sources/CanopyApp/AppModel.swift
+++ b/Sources/CanopyApp/AppModel.swift
@@ -70,9 +70,12 @@ final class AppModel {
             }
         }
         await startControlServer()
+        portsCollapsed = await workspace.portsCollapsed
+        startScanningPorts()
     }
 
     func shutdown() {
+        portsTask?.cancel()
         server?.stop()
         server = nil
         terminals.closeAll()
@@ -168,6 +171,53 @@ final class AppModel {
         }
     }
 
+    // MARK: Ports
+
+    private(set) var ports: [PortGroup] = []
+    /// Ports whose processes are being stopped, shown dimmed until they close.
+    private(set) var stoppingPorts: Set<ListeningPort> = []
+    var portsCollapsed = false {
+        didSet {
+            guard portsCollapsed != oldValue else { return }
+            let collapsed = portsCollapsed
+            perform { try await $0.setPortsCollapsed(collapsed) }
+        }
+    }
+    @ObservationIgnored private var portsTask: Task<Void, Never>?
+
+    /// Scans every 2 seconds while any part of the window can be seen.
+    private func startScanningPorts() {
+        portsTask = Task { [weak self] in
+            while !Task.isCancelled {
+                if NSApp.occlusionState.contains(.visible) {
+                    await self?.refreshPorts()
+                }
+                try? await Task.sleep(for: .seconds(2))
+            }
+        }
+    }
+
+    func refreshPorts() async {
+        let groups = await rows.portGroups()
+        if groups != ports {
+            ports = groups
+        }
+    }
+
+    func stop(_ ports: [ListeningPort]) {
+        stoppingPorts.formUnion(ports)
+        Task {
+            _ = await PortStopper().stop(ports)
+            await refreshPorts()
+            stoppingPorts.subtract(ports)
+        }
+    }
+
+    /// The other ports a port's process listens on, which stopping it closes too.
+    func otherPorts(of port: ListeningPort) -> [UInt16] {
+        ports.flatMap(\.ports).filter { $0.pid == port.pid && $0.port != port.port }.map(\.port)
+    }
+
     // MARK: Terminals
 
     func context(for row: Row) -> PaneContext {
```

`Sources/CanopyApp/Sidebar/PortsPanel.swift` (new):

```swift
import CanopyCore
import SwiftUI

/// The ports rows' processes listen on, grouped by row, at the bottom of the sidebar.
struct PortsPanel: View {
    @Environment(AppModel.self) private var model

    private var count: Int { model.ports.reduce(0) { $0 + $1.ports.count } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { model.portsCollapsed.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(model.portsCollapsed ? 0 : 90))
                    Text("Ports")
                        .textCase(.uppercase)
                    if model.portsCollapsed, count > 0 {
                        Text(verbatim: "\(count)")
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(model.portsCollapsed ? "Show ports" : "Hide ports")

            if !model.portsCollapsed {
                if model.ports.isEmpty {
                    Text("Nothing is listening in your rows.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(model.ports, id: \.rowPath) { group in
                                PortGroupView(group: group)
                            }
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    // As tall as its groups, up to a limit, so many ports scroll rather than squeeze the rows.
                    .frame(maxHeight: 220)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct PortGroupView: View {
    @Environment(AppModel.self) private var model
    let group: PortGroup

    private var name: String { model.snapshot.row(path: group.rowPath)?.displayName ?? group.rowPath }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Button(name) { model.selectedRowPath = group.rowPath }
                    .buttonStyle(.plain)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("Show \(name)")
                Spacer(minLength: 4)
                Button {
                    model.stop(group.ports)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(group.ports.count == 1 ? "Stop what listens here" : "Stop everything listening here")
            }
            .font(.callout)
            FlowLayout(spacing: 4) {
                ForEach(group.ports, id: \.self) { port in
                    PortBadge(port: port)
                }
            }
        }
    }
}

struct PortBadge: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let port: ListeningPort

    private var isStopping: Bool { model.stoppingPorts.contains(port) }

    var body: some View {
        HStack(spacing: 3) {
            Button {
                if let url = URL(string: "http://localhost:\(port.port)") { openURL(url) }
            } label: {
                Text(verbatim: "\(port.port)")
                    .monospacedDigit()
            }
            .buttonStyle(.plain)
            .help("\(port.process) (PID \(port.pid)). Opens http://localhost:\(port.port).")
            Button {
                model.stop([port])
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(stopHelp)
        }
        .font(.caption)
        .padding(.leading, 7)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
        .opacity(isStopping ? 0.4 : 1)
        .disabled(isStopping)
    }

    /// Stopping the process closes every port it holds, so the tooltip says which.
    private var stopHelp: String {
        let others = model.otherPorts(of: port).map { "\($0)" }
        let base = "Stop \(port.process) (PID \(port.pid))"
        guard !others.isEmpty else { return base + "." }
        return base
            + ". Its other \(others.count == 1 ? "port" : "ports"), \(others.joined(separator: ", ")), close too."
    }
}

/// Lays views out left to right, starting a new line when one fills up.
struct FlowLayout: SwiftUI.Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) -> CGSize {
        let lines = arrange(subviews, width: proposal.width ?? .infinity)
        let width = lines.map { $0.width }.max() ?? 0
        return CGSize(width: width, height: lines.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) {
        for line in arrange(subviews, width: bounds.width) {
            for item in line.items {
                subviews[item.index].place(
                    at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + line.y), proposal: .unspecified)
            }
        }
    }

    private struct Line {
        var items: [(index: Int, x: CGFloat)] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: LayoutSubviews, width: CGFloat) -> [Line] {
        var lines: [Line] = []
        var line = Line()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let x = line.items.isEmpty ? 0 : line.width + spacing
            if !line.items.isEmpty, x + size.width > width {
                lines.append(line)
                line = Line(y: line.y + line.height + spacing)
                line.items.append((index, 0))
                line.width = size.width
                line.height = size.height
            } else {
                line.items.append((index, x))
                line.width = x + size.width
                line.height = max(line.height, size.height)
            }
        }
        if !line.items.isEmpty { lines.append(line) }
        return lines
    }
}
```

`Sources/CanopyApp/Sidebar/SidebarView.swift` (modify):

```diff
--- a/Sources/CanopyApp/Sidebar/SidebarView.swift
+++ b/Sources/CanopyApp/Sidebar/SidebarView.swift
@@ -61,14 +61,21 @@ struct SidebarView: View {
             }
         }
         .safeAreaInset(edge: .bottom) {
-            Button {
-                chooseFolder(for: .addRepo)
-            } label: {
-                Label("Add Repo", systemImage: "plus")
+            VStack(spacing: 0) {
+                Divider()
+                PortsPanel()
+                    .padding(.horizontal, 12)
+                    .padding(.vertical, 8)
+                Divider()
+                Button {
+                    chooseFolder(for: .addRepo)
+                } label: {
+                    Label("Add Repo", systemImage: "plus")
+                }
+                .buttonStyle(.borderless)
+                .padding(10)
+                .frame(maxWidth: .infinity, alignment: .leading)
             }
-            .buttonStyle(.borderless)
-            .padding(10)
-            .frame(maxWidth: .infinity, alignment: .leading)
         }
         .sheet(item: $newRowRepo) { repo in
             NewRowSheet(repo: repo)
@@ -201,7 +208,7 @@ struct PullRequestNumber: View {
         Button {
             if let url = URL(string: pr.url) { openURL(url) }
         } label: {
-            Text("#\(pr.number)")
+            Text(verbatim: "#\(pr.number)")
                 .font(.callout)
                 .monospacedDigit()
                 .foregroundStyle(pr.state.style(on: prominence))
```

`Sources/CanopyCore/State/AppState.swift` (modify):

```diff
--- a/Sources/CanopyCore/State/AppState.swift
+++ b/Sources/CanopyCore/State/AppState.swift
@@ -31,6 +31,7 @@ public struct AppState: Codable, Sendable, Equatable {
     public var terminals: [String: SavedRowTerminals]
     /// The next pane number, so a pane ID an agent kept never names a different terminal after a relaunch.
     public var nextPane = 1
+    public var portsCollapsed = false
 
     public init(
         version: Int = AppState.currentVersion, repos: [RepoEntry] = [], selectedRowPath: String? = nil,
@@ -49,6 +50,7 @@ public struct AppState: Codable, Sendable, Equatable {
         selectedRowPath = try container.decodeIfPresent(String.self, forKey: .selectedRowPath)
         // Layouts that cannot be read are dropped on their own, so repos and rows still load.
         nextPane = try container.decodeIfPresent(Int.self, forKey: .nextPane) ?? 1
+        portsCollapsed = try container.decodeIfPresent(Bool.self, forKey: .portsCollapsed) ?? false
         terminals = (try? container.decodeIfPresent([String: SavedRowTerminals].self, forKey: .terminals)) ?? [:]
     }
 }
```

`Sources/CanopyCore/Workspace/Workspace.swift` (modify):

```diff
--- a/Sources/CanopyCore/Workspace/Workspace.swift
+++ b/Sources/CanopyCore/Workspace/Workspace.swift
@@ -216,6 +216,16 @@ public actor Workspace {
         try save()
     }
 
+    public var portsCollapsed: Bool {
+        state.portsCollapsed
+    }
+
+    public func setPortsCollapsed(_ collapsed: Bool) throws {
+        guard state.portsCollapsed != collapsed else { return }
+        state.portsCollapsed = collapsed
+        try save()
+    }
+
     public func setSelectedRow(path: String?) throws {
         guard state.selectedRowPath != path else { return }
         state.selectedRowPath = path
```

- [ ] **Step 4: Check it by eye**

Run: `make app`, register a repo with two rows, and start listeners in one row's folder and in the other row's terminal.
Expected, in dark and light mode: each row's ports under its branch, wrapping, scrolling past 220 points, "PORTS 61" when collapsed after a relaunch, and "Nothing is listening in your rows." with none.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "feat: the ports panel"
```

## After Review

An independent review found no blockers.
One commit, `fix: address review of ports`, fixes what it found, and the branch is the reference for it:
- Ports in the system's random range, 49152 and up by default, are left out.
  Every agent session runs MCP servers on such ports, so each agent's row showed extra badges, and a row's `x` would have stopped them mid-task.
  The spec says so now.
- A port is one entry however many processes share its socket, such as a server's workers, and stopping it stops all of them.
- The panel stops what a fresh scan finds on a row's ports at click time, not the pids it last saw, so a server that restarted is still the one stopped and a reused pid is never signalled.
  The app also rescans as soon as it comes back into view.
- `canopy ports stop` resolves the caller's row and refuses a port in another row with `port_in_other_row`, unless given that `--row` or `--all`.
  Two servers can hold one port number on different addresses, and an agent should not stop another agent's server.
- Stopping sends SIGCONT after SIGTERM, so a server paused with Ctrl-Z runs its shutdown handler instead of being killed.
- Badge tooltips are plain strings, since SwiftUI formats numbers in string literals ("PID 12,345").
- The panel reads its collapsed state before it first draws, shows nothing rather than "Nothing is listening" before the first scan, keeps only the newest scan's result, and disables a row's `x` while its ports stop.
- The scanner test now accepts its connection, so it fails if the listening-state filter goes, and the stopper tests clean up their processes.

Two test commits give slow machines room: the socket test reader retries interrupted reads like the client does, and the 200,000-line terminal test gets 60 seconds.
