# Canopy Control Socket Flake Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the control socket tests from failing in a loaded full run with "Canopy closed the connection before replying," a different test each time.
The client's wait for a reply must survive the kernel draining its socket from outside the process, and so must the tests' own raw connections.

**Architecture:** A new internal `SocketStream` in `CanopyCore` reads and writes a connected socket by waiting in poll(2), never inside read(2) or write(2).
`ControlClient.send` uses it instead of blocking reads bounded by `SO_RCVTIMEO`, and so do the agent hook's `ControlClient.post` from PR 21 and the tests' raw connections.
The timeout becomes a deadline for the whole exchange, counted from when the request starts to go out.

**Tech Stack:** Swift 6.2, Darwin `poll(2)` and libproc, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-27-canopy-design.md`, "Control API" > "Transport" and "Ports" > "Scanning".
The spec says nothing about how the client waits, so it does not change.

## Root Cause

What was known: while other agents built, about one full `make test` in four to seven failed in a control socket test with "Canopy closed the connection before replying."
The in-process test client's `read` failed with `EBADF`, its `close` right after succeeded, and an interposed `close()` spy found nothing closing that descriptor.

Nothing closes it.
The kernel returns EBADF from a read on a socket that is still open, because another process drained it.

### Evidence

1. The client's socket was guarded with `change_fdguard_np(fd, NULL, 0, &guard, GUARD_CLOSE | GUARD_DUP, NULL)`, where `GUARD_CLOSE` is bit 0 and `GUARD_DUP` bit 1, so any other close of it would crash with `EXC_GUARD`.
   20 loaded full runs of `main` gave no `EXC_GUARD`, but no socket failure either.
   30 more unguarded runs of `main`, with the client logging its descriptor's state on failure, also gave none: since PR 14 took the tests' git off the xcrun shim, the flake has become rare at this load.
2. The same logging on `de3a8d1`, the commit before PR 14, caught it in 2 of 16 loaded runs.
   Both times, after `read` failed with EBADF, the descriptor was still open and still the same socket: same inode, same kernel socket address, same peer.
   Its `soi_state` had gone from `0x2`, connected, to `0x4002`, connected and `SOI_S_DRAINING`.
3. Draining is how the kernel wakes threads blocked on a descriptor that is being closed.
   When `close` finds another I/O reference on the descriptor, it calls the socket's drain, which sets `SS_DRAINING` on the socket itself and wakes its sleepers, and a read or write sleeping on that socket then returns EBADF.
   The flag belongs to the socket, not the descriptor, so it reaches every process that holds a copy, and it never clears.
4. `proc_pidfdinfo` holds such a reference on another process's descriptor while it reads it.
5. Every new process starts with copies of its parent's descriptors and closes the ones it does not keep: the pty child's close sweep after `forkpty`, and the kernel itself during `posix_spawn` with `POSIX_SPAWN_CLOEXEC_DEFAULT`, or for close-on-exec descriptors.

Small C programs showed each step on this Mac:

- A thread blocked reading a socket, while a forked child closed its copy and the parent read that copy with `proc_pidfdinfo`: the reader woke with EBADF in 71 of 300 trials.
  A child that exited without closing its copy: 0 of 300.
- The same with `posix_spawn`: 101 of 400 with `POSIX_SPAWN_CLOEXEC_DEFAULT`, 91 of 400 when the socket was close-on-exec, and 0 of 400 only when the child kept the socket until it exited.
- A read that is already waiting when the socket drains wakes with EBADF.
  Once drained, a blocking read that would have to wait fails with EBADF at once, and a reply that arrives later stays in the buffer.
  A blocking write that would have to wait fails the same way, after 8 KB, and so does a TCP connect that has to wait for its handshake.
  poll(2) waits normally, and a non-blocking read after it returns the reply.

The suite does all of this at once.
Tests start git, gh, perl, and shells all the time, and each child briefly holds a copy of every in-flight client socket.
Port scans read every socket of every process of the user: the port tests in the same process, other agents' test runs, and the installed Canopy's ports panel every 2 seconds.
That is why a different test failed each time, why it needed load, which keeps a starting child preempted longer, and why the close spy saw nothing: the close happens in another process.

### In the real app

The app's control connections are not exposed.
Network.framework guards its listening and accepted sockets with `GUARD_CLOSE | GUARD_DUP`, and a guarded descriptor is copied neither into a forked child nor into a `posix_spawn` child, so no terminal, git, or gh the app starts ever holds one.
Those sockets are also non-blocking, so they would not sleep in read(2) even if a copy were drained.
The CLI waits in its own process, which starts no children while it waits.

Canopy's port scanner can do this to other programs, though.
A program of the user that sleeps in a socket read while it starts a child can get EBADF if a scan reads that child's copy as it starts.
`lsof` and Activity Monitor can do the same.

## Global Constraints

- Swift 6 language mode with strict concurrency, and no warnings.
- `make lint` passes `swift format lint --strict`.
- No change to the wire format, to any timeout the app or CLI uses, or to what the CLI prints.
- Blocking work never runs on the Swift concurrency pool.

## Review Focus

1. A reply that never comes: the client still gives up at its timeout, now through poll(2) instead of `SO_RCVTIMEO`.
   Pinned by `stopsWaitingAtTheDeadline` in Task 1.
2. No timeout, as the CLI uses for `row new`, `row rm`, and `repo clone`: the client waits as long as the app takes.
   Pinned by `waitsWithoutADeadlineUntilDataArrives` in Task 1.
3. The app closes the connection without replying: the CLI still says "Canopy closed the connection before replying."
   `SocketStream.read` returns no bytes, pinned by `readsNothingOnceTheOtherSideCloses`, and `send` turns that into `connectionClosed`.
4. A request bigger than the socket's buffer, or an app slow to read it: the write waits in poll(2) too, even on a drained socket.
   Pinned by `writesMoreThanTheBufferHoldsOnADrainedSocket` in Task 1.
5. A reply that arrives in several pieces: `send` keeps reading until the newline, as before.
   Pinned by the existing `ControlServerTests`, whose row and terminal listings are the longest replies.

## Decisions to Review

1. **The waiting side is fixed here; the scanner is a follow-up.**
   `lsof`, Activity Monitor, other agents' test runs, and Canopy builds from before a scanner change would still drain sockets, so the client has to cope either way.
   The only public way to find which process listens on a port is `proc_pidfdinfo`; the kernel's TCP table with owner pids, `net.inet.tcp.pcblist_n`, uses private structures.
   Canopy's own scans can still be made far gentler on other programs, as the review suggested: attribute each process to a row first, which only needs its parent chain and working folder, and read sockets only for processes in rows.
   Nothing uses a port outside every row, since `canopy ports`, stopping a port, and the panel all attribute first, and `PortStopper`'s rescan can read only the pids it is stopping.
   It changes what the spec's "Scanning" section says Canopy lists, so it is left for its own PR.
2. **The timeout is a deadline for the whole exchange,** counted from when the request starts to go out, instead of `SO_RCVTIMEO`'s limit on each read.
   A reply that trickles in can no longer stretch it, and an app that stops reading a request now times out instead of blocking the CLI forever.
3. **No descriptor guard.**
   Guarding the client's socket would keep it out of children entirely, but `change_fdguard_np` is private API.
4. **The tests' raw `exchange` waits up to 60 seconds instead of 10,** like the client `startServer` returns.
   One run at a load average of 70 failed `overLongLinesAreRejected` after 31 seconds with no reply.
   A drain fails at once rather than after a wait, so that one was plain slowness: a 1 MB request in a debug build, under that load.
5. **Task 4 is an unrelated race, fixed here because it failed a loaded run.**
   It touches row creation from PR 17, so it can move to its own PR if the author prefers.

---

## Task 1: Wait for control replies in poll

**Files:**
- Create: `Sources/CanopyCore/Control/SocketStream.swift`
- Modify: `Sources/CanopyCore/Control/ControlClient.swift`
- Create: `Tests/CanopyCoreTests/Support/SocketDrain.swift`
- Create: `Tests/CanopyCoreTests/SocketStreamTests.swift`
- Test: `Tests/CanopyCoreTests/ControlServerTests.swift`

**Interfaces:**
- Produces: `struct SocketStream` with `init(fd: Int32, deadline: ContinuousClock.Instant?)`, `func write(_ data: Data) throws`, and `func read() throws -> Data`, internal to `CanopyCore`.
  It throws `ControlClientError.timedOut`, `.connectionClosed`, and `.writeFailed(errno:)`.
- Produces: `ControlClient.send(_ request: ControlRequest, over fd: Int32) throws -> ControlResponse`, internal.
- Produces (tests): `func drainSocket(_ fd: Int32) -> Bool` and `func isDraining(_ fd: Int32) -> Bool`.

- [ ] **Step 1: Let `send` take a socket that is already connected**

In `Sources/CanopyCore/Control/ControlClient.swift`, split `send` so a test can hand it a socket, with no change in behavior yet:

```swift
    public func send(_ request: ControlRequest) throws -> ControlResponse {
        let fd = try Self.connect(to: socketPath)
        defer { close(fd) }
        return try send(request, over: fd)
    }

    /// Sends `request` on a socket already connected to the app and waits for the reply.
    func send(_ request: ControlRequest, over fd: Int32) throws -> ControlResponse {
        if let timeout {
        // ...the rest of the old body, unchanged...
```

- [ ] **Step 2: Add a test helper that drains a socket**

A test cannot wait for a port scan to hit a starting child.
Closing a copy of the socket in this process while another thread reads that copy with `proc_pidfdinfo` makes the kernel drain it the same way, within a few tries, and touches no other test's descriptors.

Create `Tests/CanopyCoreTests/Support/SocketDrain.swift`:

```swift
import Foundation
import Synchronization

/// Marks `fd`'s socket as draining, and returns whether the kernel reports it so within 20 seconds.
///
/// A process that closes its copy of a socket while another process reads that copy with proc_pidfdinfo, as port
/// scans and `lsof` do, makes the kernel drain the socket itself, in every process that holds it. Every new child
/// closes its copies of the parent's sockets as it starts. Here a copy in this process is closed while a thread reads
/// it, which the kernel treats the same way. It blocks, so call it through `offPool`.
func drainSocket(_ fd: Int32) -> Bool {
    // One drain at a time: under a low descriptor limit only one slot is left at the top for the copy.
    drainLock.withLock { _ in drainAlone(fd) }
}

private let drainLock = Mutex(())

private func drainAlone(_ fd: Int32) -> Bool {
    // Copies sit far above the numbers other tests get, which are handed out lowest first, so the reading thread never
    // reads another test's descriptor.
    var limit = rlimit()
    getrlimit(RLIMIT_NOFILE, &limit)
    let floor = Int32(clamping: Int(clamping: min(limit.rlim_cur, 4096)) - 1)
    let target = DrainTarget()
    Thread {
        var info = socket_fdinfo()
        while !target.done.load(ordering: .relaxed) {
            let copy = target.copy.load(ordering: .relaxed)
            if copy >= 0 {
                _ = proc_pidfdinfo(getpid(), copy, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size))
            }
        }
    }.start()
    defer { target.done.store(true, ordering: .relaxed) }
    let deadline = ContinuousClock.now + .seconds(20)
    while !isDraining(fd) {
        guard ContinuousClock.now < deadline else { return false }
        let copy = fcntl(fd, F_DUPFD_CLOEXEC, floor)
        guard copy >= 0 else { return false }
        target.copy.store(copy, ordering: .relaxed)
        usleep(10)
        target.copy.store(-1, ordering: .relaxed)
        close(copy)
    }
    return true
}

func isDraining(_ fd: Int32) -> Bool {
    var info = socket_fdinfo()
    let size = Int32(MemoryLayout<socket_fdinfo>.size)
    return proc_pidfdinfo(getpid(), fd, PROC_PIDFDSOCKETINFO, &info, size) == size
        && Int32(info.psi.soi_state) & SOI_S_DRAINING != 0
}

private final class DrainTarget: Sendable {
    let copy = Atomic<Int32>(-1)
    let done = Atomic(false)
}
```

- [ ] **Step 3: Write the failing test**

In `Tests/CanopyCoreTests/ControlServerTests.swift`, before `repliesComeInRequestOrder`:

```swift
    /// Every child a test starts gets a copy of the client's socket and closes it as it starts. A port scan reading
    /// that copy at that moment drains the socket, and a read that sleeps on a drained socket fails with EBADF even
    /// once the reply is there, which failed a different test in about one loaded full run in six.
    @Test func aReplyArrivesOnADrainedSocket() async throws {
        let dir = try TempDir()
        let home = CanopyHome(path: dir.sub("home"))
        try home.ensureExists()
        let server = ControlServer(socketPath: home.socketPath) { request in
            try? await Task.sleep(for: .milliseconds(300))
            return .success(id: request.id, result: .bool(true))
        }
        try await server.start()
        defer { server.stop() }
        let socketPath = home.socketPath

        let (drained, response) = try await offPool {
            let fd = try ControlClient.connect(to: socketPath)
            defer { close(fd) }
            let drained = drainSocket(fd)
            return (drained, try ControlClient(socketPath: socketPath).send(ControlRequest(method: "slow"), over: fd))
        }

        try #require(drained)
        #expect(response.result == .bool(true))
    }
```

- [ ] **Step 4: Run it and watch it fail**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter aReplyArrivesOnADrainedSocket`
Expected: FAIL with "Caught error: Canopy closed the connection before replying.", the flake's own message.

- [ ] **Step 5: Add `SocketStream`**

Create `Sources/CanopyCore/Control/SocketStream.swift`:

```swift
import Foundation

/// Reads and writes a connected socket, waiting in poll(2) and never inside read(2) or write(2).
///
/// Every new process starts with a copy of each socket its parent has open, and closes it as it starts: in the child
/// after fork, or during posix_spawn and exec. If a port scan or `lsof` is reading that copy with proc_pidfdinfo at
/// that moment, the kernel marks the socket itself as draining, in every process that holds it. From then on a read or
/// write that has to wait fails with EBADF at once, even while a reply is on its way. A wait in poll(2) is unaffected.
struct SocketStream {
    let fd: Int32
    /// When to stop waiting. Nil waits as long as it takes.
    let deadline: ContinuousClock.Instant?

    /// Makes `fd` non-blocking.
    init(fd: Int32, deadline: ContinuousClock.Instant?) {
        self.fd = fd
        self.deadline = deadline
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written >= 0 {
                    offset += written
                    continue
                }
                let code = errno
                guard code == EINTR || code == EAGAIN else { throw ControlClientError.writeFailed(errno: code) }
                guard try wait(for: POLLOUT) else { throw ControlClientError.writeFailed(errno: errno) }
            }
        }
    }

    /// Whatever has arrived, once at least one byte has. Empty when the other side has closed.
    func read() throws -> Data {
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count >= 0 {
                return Data(chunk[0..<count])
            }
            let code = errno
            guard code == EINTR || code == EAGAIN, try wait(for: POLLIN) else {
                throw ControlClientError.connectionClosed
            }
        }
    }

    /// Returns once `event` may be ready, or false if poll(2) itself failed, with `errno` set.
    private func wait(for event: Int32) throws -> Bool {
        var request = pollfd(fd: fd, events: Int16(event), revents: 0)
        while true {
            var limit: Int32 = -1
            if let deadline {
                let left = deadline - .now
                guard left > .zero else { throw ControlClientError.timedOut }
                limit = Int32(clamping: Int((left / .milliseconds(1)).rounded(.up)))
            }
            let ready = poll(&request, 1, limit)
            if ready > 0 {
                return true
            }
            if ready < 0 && errno != EINTR && errno != EAGAIN {
                return false
            }
        }
    }
}
```

- [ ] **Step 6: Send and post through it**

Replace the body of `send(_:over:)` with one that uses the stream, and say when the timeout starts counting.
`post`, which the agent hook uses, waits the same way within its one-second limit, and still ignores how the reply ends; the static `write(_:to:)` it shared with `send` goes.
With Step 1's split, the whole change to `Sources/CanopyCore/Control/ControlClient.swift` is:

```diff
--- a/Sources/CanopyCore/Control/ControlClient.swift
+++ b/Sources/CanopyCore/Control/ControlClient.swift
@@ -26,7 +26,8 @@ public enum ControlClientError: Error, Equatable, CustomStringConvertible {
 /// A blocking client for one request at a time. The CLI makes a single call per run.
 public struct ControlClient: Sendable {
     public var socketPath: String
-    /// How long to wait for the reply. Nil waits as long as the app takes.
+    /// How long to wait for the reply, counted from when the request starts to go out.
+    /// Nil waits as long as the app takes.
     public var timeout: TimeInterval?
 
     public init(socketPath: String, timeout: TimeInterval? = 120) {
@@ -43,24 +44,18 @@ public struct ControlClient: Sendable {
     public func send(_ request: ControlRequest) throws -> ControlResponse {
         let fd = try Self.connect(to: socketPath)
         defer { close(fd) }
+        return try send(request, over: fd)
+    }
 
-        if let timeout {
-            var receiveTimeout = timeval(tv_sec: Int(timeout), tv_usec: 0)
-            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))
-        }
-
-        try Self.write(try ControlCodec.encodeLine(request), to: fd)
-
+    /// Sends `request` on a socket already connected to the app and waits for the reply.
+    func send(_ request: ControlRequest, over fd: Int32) throws -> ControlResponse {
+        let stream = SocketStream(fd: fd, deadline: timeout.map { .now + .seconds($0) })
+        try stream.write(try ControlCodec.encodeLine(request))
         var received = Data()
-        var chunk = [UInt8](repeating: 0, count: 65_536)
         while !received.contains(0x0A) {
-            let count = read(fd, &chunk, chunk.count)
-            if count == 0 { throw ControlClientError.connectionClosed }
-            if count < 0 && errno == EINTR { continue }
-            if count < 0 {
-                throw errno == EAGAIN ? ControlClientError.timedOut : ControlClientError.connectionClosed
-            }
-            received.append(contentsOf: chunk[0..<count])
+            let chunk = try stream.read()
+            if chunk.isEmpty { throw ControlClientError.connectionClosed }
+            received.append(chunk)
         }
         let line = received.prefix { $0 != 0x0A }
         return try ControlCodec.decode(ControlResponse.self, from: Data(line))
@@ -72,28 +67,9 @@ public struct ControlClient: Sendable {
     public func post(_ request: ControlRequest, timeout: TimeInterval = 1) throws {
         let fd = try Self.connect(to: socketPath)
         defer { close(fd) }
-        var limit = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000))
-        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
-        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
-        try Self.write(try ControlCodec.encodeLine(request), to: fd)
-        var chunk = [UInt8](repeating: 0, count: 4096)
-        while true {
-            let count = read(fd, &chunk, chunk.count)
-            if count < 0 && errno == EINTR { continue }
-            if count <= 0 || chunk[0..<count].contains(0x0A) { return }
-        }
-    }
-
-    static func write(_ data: Data, to fd: Int32) throws {
-        try data.withUnsafeBytes { raw in
-            var offset = 0
-            while offset < raw.count {
-                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
-                if written < 0 && errno == EINTR { continue }
-                if written < 0 { throw ControlClientError.writeFailed(errno: errno) }
-                offset += written
-            }
-        }
+        let stream = SocketStream(fd: fd, deadline: .now + .seconds(timeout))
+        try stream.write(try ControlCodec.encodeLine(request))
+        while let chunk = try? stream.read(), !chunk.isEmpty, !chunk.contains(0x0A) {}
     }
 
     static func connect(to path: String) throws -> Int32 {
```

- [ ] **Step 7: Test `SocketStream` on its own**

Create `Tests/CanopyCoreTests/SocketStreamTests.swift`:

```swift
import Foundation
import Testing

@testable import CanopyCore

struct SocketStreamTests {
    /// Both ends of a connected socket pair, closed when the test ends.
    final class Pair: Sendable {
        let near: Int32
        let far: Int32

        init() throws {
            var ends: [Int32] = [-1, -1]
            try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &ends) == 0)
            near = ends[0]
            far = ends[1]
        }

        deinit {
            close(near)
            close(far)
        }
    }

    @Test func stopsWaitingAtTheDeadline() async throws {
        let pair = try Pair()
        let clock = ContinuousClock()
        let start = clock.now

        await #expect(throws: ControlClientError.timedOut) {
            try await offPool { try SocketStream(fd: pair.near, deadline: .now + .milliseconds(300)).read() }
        }

        #expect(clock.now - start >= .milliseconds(300))
        #expect(clock.now - start < .seconds(10))
    }

    /// The CLI waits without a deadline for requests that take as long as they take, such as `canopy row new`.
    @Test func waitsWithoutADeadlineUntilDataArrives() async throws {
        let pair = try Pair()
        let stream = SocketStream(fd: pair.near, deadline: nil)

        async let received = offPool { try stream.read() }
        try await Task.sleep(for: .milliseconds(300))
        _ = "late".withCString { write(pair.far, $0, 4) }

        #expect(String(decoding: try await received, as: UTF8.self) == "late")
    }

    @Test func readsNothingOnceTheOtherSideCloses() async throws {
        let pair = try Pair()
        _ = "last".withCString { write(pair.far, $0, 4) }
        shutdown(pair.far, SHUT_WR)
        let stream = SocketStream(fd: pair.near, deadline: .now + .seconds(20))

        let (first, second) = try await offPool { (try stream.read(), try stream.read()) }

        #expect(String(decoding: first, as: UTF8.self) == "last")
        #expect(second.isEmpty)
    }

    /// As in the suite: the socket is drained while a read is already waiting for the reply.
    @Test func readsAReplyAfterADrainMidWait() async throws {
        let pair = try Pair()
        let stream = SocketStream(fd: pair.near, deadline: .now + .seconds(60))

        async let received = offPool { try stream.read() }
        try await Task.sleep(for: .milliseconds(100))
        let drained = try await offPool { drainSocket(pair.near) }
        if drained {
            _ = "reply".withCString { write(pair.far, $0, 5) }
        } else {
            // Ends the read now rather than at its deadline.
            shutdown(pair.far, SHUT_WR)
        }

        try #require(drained)

        #expect(String(decoding: try await received, as: UTF8.self) == "reply")
    }

    /// A write that fills the socket's buffer has to wait for the other side, and a write that sleeps on a drained
    /// socket fails with EBADF.
    @Test func writesMoreThanTheBufferHoldsOnADrainedSocket() async throws {
        let pair = try Pair()
        try #require(try await offPool { drainSocket(pair.near) })
        let payload = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0) })
        let far = SocketStream(fd: pair.far, deadline: .now + .seconds(60))

        async let received = offPool { () throws -> Data in
            var received = Data()
            while received.count < payload.count {
                let chunk = try far.read()
                if chunk.isEmpty { break }
                received.append(chunk)
            }
            return received
        }
        let wrote = try await offPool {
            Result { try SocketStream(fd: pair.near, deadline: .now + .seconds(60)).write(payload) }
        }
        shutdown(pair.near, SHUT_WR)

        try wrote.get()
        #expect(try await received == payload)
    }
}
```

- [ ] **Step 8: Run the tests**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter "SocketStreamTests|ControlServerTests"`
Expected: all pass.
As a check that the drain tests mean something, clear `O_NONBLOCK` at the top of `write`: `writesMoreThanTheBufferHoldsOnADrainedSocket` then fails with "Could not send to Canopy: Bad file descriptor."
Clearing it at the top of `read` instead makes `readsAReplyAfterADrainMidWait` fail with "Canopy closed the connection before replying."

- [ ] **Step 9: Commit**

```bash
git add Sources/CanopyCore/Control/SocketStream.swift Sources/CanopyCore/Control/ControlClient.swift \
    Tests/CanopyCoreTests/Support/SocketDrain.swift Tests/CanopyCoreTests/SocketStreamTests.swift \
    Tests/CanopyCoreTests/ControlServerTests.swift
git commit -m "fix: wait for control replies in poll, so a socket another process drained still delivers them"
```

## Task 2: Read the tests' raw connections the same way

`exchange` and `malformedLineGetsBadRequest` open their own connections and sleep in read(2), so a drain fails them too.

**Files:**
- Modify: `Tests/CanopyCoreTests/ControlServerTests.swift`

**Interfaces:**
- Consumes: `SocketStream` from Task 1.

- [ ] **Step 1: Move both onto `SocketStream`**

`exchange` ignores write errors as before, since the server hangs up on an over-long line before taking all of it.

```diff
--- a/Tests/CanopyCoreTests/ControlServerTests.swift
+++ b/Tests/CanopyCoreTests/ControlServerTests.swift
@@ -501,37 +501,28 @@ struct ControlServerTests {
         let (_, server, _, _) = try await startServer(dir)
         defer { server.stop() }
 
-        let socketPath = dir.sub("home/canopy.sock")
-        let reply = try await offPool { () throws -> Data in
-            let fd = try ControlClient.connect(to: socketPath)
-            defer { close(fd) }
-            _ = "not json\n".withCString { write(fd, $0, strlen($0)) }
-            var buffer = [UInt8](repeating: 0, count: 4096)
-            let count = read(fd, &buffer, buffer.count)
-            return Data(buffer[0..<max(count, 0)].prefix { $0 != 0x0A })
-        }
-        let response = try ControlCodec.decode(ControlResponse.self, from: reply)
+        let replies = try await exchange(dir.sub("home/canopy.sock"), Data("not json\n".utf8))
+
+        let response = try ControlCodec.decode(ControlResponse.self, from: Data(try #require(replies.first).utf8))
         #expect(response.error?.code == "bad_request")
     }
 
     /// Sends `payload` on a raw connection, optionally closes the write side, and reads until `lines` replies arrive.
+    /// The server may hang up before taking all of `payload`, so write errors are left to show as missing replies.
     func exchange(_ socketPath: String, _ payload: Data, halfClose: Bool = false, lines: Int = 1) async throws
         -> [String]
     {
         try await offPool {
             let fd = try ControlClient.connect(to: socketPath)
             defer { close(fd) }
-            var timeout = timeval(tv_sec: 10, tv_usec: 0)
-            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
-            _ = payload.withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }
+            let stream = SocketStream(fd: fd, deadline: .now + .seconds(60))
+            try? stream.write(payload)
             if halfClose { shutdown(fd, SHUT_WR) }
             var received = Data()
-            var chunk = [UInt8](repeating: 0, count: 65_536)
             while received.filter({ $0 == 0x0A }).count < lines {
-                let count = read(fd, &chunk, chunk.count)
-                if count < 0 && errno == EINTR { continue }
-                guard count > 0 else { break }
-                received.append(contentsOf: chunk[0..<count])
+                let chunk = try stream.read()
+                guard !chunk.isEmpty else { break }
+                received.append(chunk)
             }
             return String(decoding: received, as: UTF8.self).split(separator: "\n").map(String.init)
         }
```

- [ ] **Step 2: Run the control server tests**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter ControlServerTests`
Expected: all pass.

- [ ] **Step 3: Commit**

```bash
git add Tests/CanopyCoreTests/ControlServerTests.swift
git commit -m "test: read raw control connections through SocketStream too"
```

## Task 3: Connect and accept in poll in the port scanner test

`connectionsAndClosedListenersAreNotListed` connects to a loopback listener and accepts.
A TCP connect that sleeps for its handshake fails with `ECONNABORTED` on a drained socket, and the blocking `accept` after it would then wait forever and hang the whole run.

**Files:**
- Modify: `Tests/CanopyCoreTests/PortScannerTests.swift`

- [ ] **Step 1: Wait in poll for both**

```diff
--- a/Tests/CanopyCoreTests/PortScannerTests.swift
+++ b/Tests/CanopyCoreTests/PortScannerTests.swift
@@ -75,20 +75,28 @@ struct PortScannerTests {
     @Test func connectionsAndClosedListenersAreNotListed() throws {
         var listener: Listener? = try Listener()
         let port = try #require(listener?.port)
+        let listening = try #require(listener?.fd)
         let client = socket(AF_INET, SOCK_STREAM, 0)
         defer { close(client) }
+        // Connecting and accepting wait in poll: a connect or accept that sleeps fails, or never returns, once a child
+        // starting meanwhile has drained the socket. See SocketStream.
+        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) | O_NONBLOCK)
         var address = sockaddr_in()
         address.sin_family = sa_family_t(AF_INET)
         address.sin_port = port.bigEndian
         address.sin_addr.s_addr = UInt32(0x7f00_0001).bigEndian
-        let connected = withUnsafePointer(to: &address) {
+        let (started, code) = withUnsafePointer(to: &address) {
             $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
-                connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
+                (connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)), errno)
             }
         }
-        #expect(connected == 0)
+        try #require(started == 0 || code == EINPROGRESS)
+        try #require(waitUntil(client, can: POLLOUT) && waitUntil(listening, can: POLLIN))
+        var error: Int32 = 0
+        var size = socklen_t(MemoryLayout<Int32>.size)
+        #expect(getsockopt(client, SOL_SOCKET, SO_ERROR, &error, &size) == 0 && error == 0)
         // The accepted socket has the listener's port as its local port, but it is not listening.
-        let accepted = accept(try #require(listener?.fd), nil, nil)
+        let accepted = accept(listening, nil, nil)
         defer { close(accepted) }
         #expect(accepted >= 0)
         #expect(mine(port).count == 1)
@@ -97,6 +105,15 @@ struct PortScannerTests {
 
         #expect(mine(port).isEmpty)
     }
+
+    func waitUntil(_ fd: Int32, can event: Int32) -> Bool {
+        var request = pollfd(fd: fd, events: Int16(event), revents: 0)
+        var ready = poll(&request, 1, 20_000)
+        while ready < 0 && errno == EINTR {
+            ready = poll(&request, 1, 20_000)
+        }
+        return ready == 1
+    }
 }
 
 struct ProcessTableTests {
```

- [ ] **Step 2: Run the port scanner tests**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter PortScannerTests`
Expected: all pass.

- [ ] **Step 3: Commit**

```bash
git add Tests/CanopyCoreTests/PortScannerTests.swift
git commit -m "test: connect and accept in poll in the port scanner test, so a drained socket cannot hang the suite"
```

## Task 4: Look again before refusing a branch the main checkout has just left

Not part of the socket flake, but it failed one of the loaded runs, so it is fixed here.
`createRow` refuses a branch that another row has checked out, and it checks that against the snapshot before fetching.
The workspace refreshes 200 ms after git changes a checkout's branch, so right after `git switch main` in the main checkout, the snapshot still shows it on the old branch.
`keepsCommitsThatAreOnlyLocal` switches the main checkout to `feat/x` and back and then asks for `feat/x`, and under load the refresh in between left the snapshot on `feat/x`.
A user who runs `git switch main` and then `canopy row new feat/x` at once gets the same false "is checked out in" error.

**Files:**
- Modify: `Sources/CanopyCore/Workspace/Workspace+RowLifecycle.swift`
- Test: `Tests/CanopyCoreTests/ExistingBranchTests.swift`

- [ ] **Step 1: Write the failing test**

In `Tests/CanopyCoreTests/ExistingBranchTests.swift`, before `neverResetsADivergedBranch`:

```swift
    /// The workspace refreshes a moment after a checkout changes branch, and a row asked for in between must not be
    /// refused because of the branch the checkout just left.
    @Test func aBranchTheMainCheckoutJustLeftIsFree() async throws {
        let dir = try TempDir()
        let (repo, _, workspace) = try await setUp(dir)
        try await git.run(["switch", "--quiet", "-c", "feat/x"], in: repo)
        #expect(await eventually { await workspace.snapshot.repo(path: repo)?.rows.first?.branch == "feat/x" })
        // No watcher from here on, so the snapshot still shows feat/x however long the switch back takes.
        await workspace.stop()
        try await git.run(["switch", "--quiet", "main"], in: repo)

        let created = try await workspace.createRow(repoPath: repo, branch: "feat/x")

        #expect(created.row.branch == "feat/x")
    }
```

- [ ] **Step 2: Run it and watch it fail**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter aBranchTheMainCheckoutJustLeftIsFree`
Expected: FAIL with `.branchCheckedOut("feat/x", row: ...)` naming the main checkout.

- [ ] **Step 3: Refresh before refusing**

```diff
--- a/Sources/CanopyCore/Workspace/Workspace+RowLifecycle.swift
+++ b/Sources/CanopyCore/Workspace/Workspace+RowLifecycle.swift
@@ -97,9 +97,13 @@ extension Workspace {
             throw WorkspaceError.pathNotFound(repoPath)
         }
         try await requireValidBranchName(requested, repoPath: repoPath)
-        // Fails before fetching, since a row that has the branch will still have it after.
-        if let holder = holder(of: requested, repoPath: repoPath), !holder.isMissing {
-            throw WorkspaceError.branchCheckedOut(requested, row: holder)
+        // Fails before fetching, since a row that has the branch will still have it after. The snapshot trails a
+        // checkout that just switched branch by a moment, so a refusal waits for a fresh look.
+        if holder(of: requested, repoPath: repoPath) != nil {
+            await refresh(repoPath: repoPath)
+            if let holder = holder(of: requested, repoPath: repoPath), !holder.isMissing {
+                throw WorkspaceError.branchCheckedOut(requested, row: holder)
+            }
         }
 
         var notes: [String] = []
```

A branch the snapshot shows as free needs no refresh: if another worktree took it meanwhile, `git worktree add` fails and the existing handler refreshes and names the holder.

- [ ] **Step 4: Run the row tests**

Run: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter "ExistingBranchTests|RowLifecycleTests|PullRequestRowTests|WorkspaceTests"`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/CanopyCore/Workspace/Workspace+RowLifecycle.swift Tests/CanopyCoreTests/ExistingBranchTests.swift
git commit -m "fix: look again before refusing a branch the main checkout has just left"
```

## Task 5: The merge bar

- [ ] `make lint` and `make build` with 0 warnings, at every commit alone.
- [ ] Three clean `make test` runs under the shared lock: `lockf -k /tmp/canopy-merge-bar.lock sh -c 'make test && make test && make test'`.
- [ ] A loaded count against `main`, with a stand-in port scanner reading every socket in the test run's own process tree as fast as it can, so the flake shows up often enough to count.
- [ ] `make e2e`.
- [ ] An independent opus reviewer on `git diff main...HEAD`, with findings fixed and listed under "After Review".
- [ ] CI `check` green.

## Results

Since PR 14 the flake is rare at the load this Mac had: no loaded run of `main` at `68c3e2c` hit it in 50, at load averages of 20 to 70, while `de3a8d1` hit it in 2 of 16.
So the counts below add a stand-in port scanner, confined to the test run's own process tree, which reads every socket of each direct child of the test process every 10 ms.
It stands in for the port tests, other agents' runs, and the installed Canopy, all of which read those children's sockets too, only less often.

| Build | Loaded full runs | Runs with "closed the connection before replying" | Such failures |
| --- | --- | --- | --- |
| `main` at `20d1fc3` | 10 | 8 | 25 |
| This branch before the review fixes | 10 | 0 | 0 |
| This branch's head | 20 | 0 | 0 |

The load average was 16 to 42 during these runs.
19 of the head's 20 runs passed completely, and the other failed the race Task 4 fixes.
The scanner also stalled fake `gh` scripts in some runs of both builds, which "Also seen" describes; the table counts only the socket failure.

The merge bar:

- `make lint`, and `swift build` and the test build with 0 warnings, at every commit alone, and `make test` passing at each.
  After the rebase onto PR 21, one run at Task 3's commit failed a single test whose log was not kept; three more runs there passed.
  The likeliest cause is the race Task 4 fixes, but that is not confirmed.
- Three `make test` runs under the shared lock: 585 of 585 each.
- `make e2e` passed.

## After Review

An independent opus review found no blockers, one important point, four minor ones, and four nits.
It checked the kernel behavior the fix relies on with probes of its own.
poll(2) on a drained socket waits and times out normally.
With a drain in the middle of a wait, poll(2) and a non-blocking read got the reply 30 times out of 30, where a blocking read got EBADF 30 times out of 30.
A closed peer ends every path, and pipes are not affected.

What was done:

- **Important: Canopy's own scanner reads every socket of every process of the user.**
  Taken as the follow-up in Decision 1, with the review's design.
- **A drained socket could hang the suite in `connectionsAndClosedListenersAreNotListed`.**
  Task 3 now connects and accepts in poll(2).
- **No test drained the socket while a read was already waiting,** which is how the suite hit it.
  `readsAReplyAfterADrainMidWait` does, and fails with a read that sleeps.
- **The drain helper's copies took the lowest free numbers,** so its reading thread could inspect a number another test had just been given.
  Copies now go at 4095, or just under the descriptor limit when that is lower.
- **The plan and `SocketStream`'s doc said a drained read fails "even once the reply has arrived."**
  It fails at once whenever it would have to wait, so the wording and Decision 4's reason are corrected.
- **Nits:** a doc line over 120 columns is wrapped.
  "In the real app" now says Network.framework's sockets are non-blocking too, and that guarded descriptors skip `posix_spawn` children as well as forked ones, which a probe confirmed.

Two nits were left as they are:

- A failure of poll(2) itself shows as "Canopy closed the connection before replying" on a read, while a write reports its errno.
  On one valid descriptor poll(2) only fails with EINTR or EAGAIN, and both are retried.
- When the deadline passes partway through writing a request, the CLI says the request "may still finish," which it cannot, since the app never got the whole line.
  The "may" covers it, and a write only waits when the app has stopped reading.

### Second round

A second opus review, of what changed after the first and of Task 4, found no blockers and nothing important.
It confirmed that Task 4's refresh cannot deadlock inside `serialized`, and that pull request rows, which already refresh in `claim`, behave as before.
All five of its points are fixed:

- Two drains at once could fail with "Too many open files" under a descriptor limit of 4096 or less, since only one slot is left above the floor, and `make test` from a terminal runs with 2048.
  `drainSocket` now runs one drain at a time.
- A failed drain in `readsAReplyAfterADrainMidWait` would have waited out the read's 60 second deadline; it now shuts down the other end at once.
- `aBranchTheMainCheckoutJustLeftIsFree` could pass without the fix under load, if the watcher's refresh landed before `createRow` looked.
  It now stops the workspace's watcher once the snapshot shows `feat/x`, and fails without the fix every time.
- The port scanner test's poll helper retries on EINTR, and sets `O_NONBLOCK` without dropping the socket's other flags.
- A failed `getrlimit` can no longer underflow the drain helper's floor.

### Also seen

The stand-in scanner also held some fake `gh` and git wrapper scripts for up to 30 seconds, in both builds: a spawned bash was still at its first instruction, `_dyld_start`, 19 seconds after `posix_spawn` returned.
It needed the full suite, where starting children carry copies of live sockets, and did not happen with the pull request suites alone or in a C program spawning 1,200 children under the same inspection.
Inspecting each new child every 10 ms is far beyond the app's scan every 2 seconds, and it was not investigated further.

Loaded runs for this branch, at load averages of 30 to 70, also failed timing bounds in tests unrelated to the socket, on `main` as well:
`slowShellGivesUpInsteadOfBlocking` (6.4 s against 5 s), `timeoutKillsGitAndEverythingItStarted` (5.5 s against 5 s), `followsAnSSHAliasWhenDispatchHasNoThreadsLeft` (12 s against 5 s), `tellsHowTheCloneIsGoing` (progress arriving already at 100%), and the timed refreshes in `PullRequestWorkspaceTests`.
They are written up for whoever takes on load flakes next.
