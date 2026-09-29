import Foundation
import Testing

@testable import CanopyCore

enum Fixture {
    /// This process's environment without the SDKROOT that `swift test` adds and the app never has.
    static let environment = ProcessInfo.processInfo.environment.filter { $0.key != "SDKROOT" }

    /// The git that /usr/bin/git hands off to. The shim asks xcrun on every run, and xcrun's cache starts empty on a
    /// fresh CI runner, so the first hundred tests to run git each started xcodebuild at once on three CPUs. Asking
    /// xcrun here would start one too, while every test waits for this value, so the path comes from xcode-select.
    static let gitPath: String = {
        let folder = try? Subprocess.run(
            "/usr/bin/xcode-select", ["--print-path"], environment: environment, directory: nil, timeout: .seconds(10))
        let path = folder.map {
            String(decoding: $0.stdout, as: UTF8.self).trimmingCharacters(in: .newlines) + "/usr/bin/git"
        }
        return path.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil } ?? "/usr/bin/git"
    }()

    /// Tests pass an explicit environment so they never depend on the login shell of whoever runs them.
    static let git = GitRunner(executable: gitPath, environment: environment)

    /// A GitRunner whose commits are made at `date`, such as 2026-09-01T10:00:00Z, or now when it is nil.
    static func git(committingAt date: String?) -> GitRunner {
        guard let date else { return git }
        return GitRunner(
            executable: gitPath,
            environment: environment.merging(["GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date]) { $1 })
    }

    /// Creates `<dir>/<name>` with one commit on `main`. With `origin`, also creates a bare
    /// `<dir>/<name>-origin.git`, pushes to it, and sets origin/HEAD.
    @discardableResult
    static func repo(in dir: TempDir, name: String = "demo", origin: Bool = false) async throws -> String {
        let path = dir.sub(name)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try await git.run(["init", "--quiet", "-b", "main"], in: path)
        try await git.run(["config", "user.email", "test@example.com"], in: path)
        try await git.run(["config", "user.name", "Test"], in: path)
        try await git.run(["commit", "--quiet", "--allow-empty", "-m", "init"], in: path)
        if origin {
            let bare = dir.sub("\(name)-origin.git")
            try await git.run(["init", "--quiet", "--bare", "-b", "main", bare])
            try await git.run(["remote", "add", "origin", bare], in: path)
            try await git.run(["push", "--quiet", "-u", "origin", "main"], in: path)
            try await git.run(["remote", "set-head", "origin", "main"], in: path)
        }
        return Paths.canonical(path)
    }

    /// A GitRunner whose git first runs `before` (bash, with the arguments in "$@"), then the real git.
    /// Use it to stall or count specific git commands.
    static func git(in dir: TempDir, before: String) throws -> GitRunner {
        let script = dir.sub("git-wrapper-\(UUID().uuidString.prefix(6))")
        let body = "#!/bin/bash\n\(before)\nexec '\(gitPath)' \"$@\"\n"
        try body.write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        return GitRunner(executable: script, environment: environment)
    }

    /// A GitHubCLI whose `gh` is a bash script running `body`, alone on PATH.
    static func gh(
        in dir: TempDir, sshConfigFile: String? = nil, _ body: String, timeout: Duration = .seconds(30)
    ) throws -> GitHubCLI {
        let bin = dir.sub("gh-bin")
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        try "#!/bin/bash\n\(body)\n".write(toFile: bin + "/gh", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin + "/gh")
        return GitHubCLI(
            environment: ["PATH": bin + ":/usr/bin:/bin", "HOME": dir.path], timeout: timeout,
            sshConfigFile: sshConfigFile)
    }

    /// Bash lines for a stand-in script that holds until the test creates `path`. It gives up and goes on after about
    /// `seconds`, as bash counts whole seconds, so a stand-in whose test was killed ends by itself.
    static func waitForFile(_ path: String, seconds: Int = 60) -> String {
        "stand_in_deadline=$((SECONDS + \(seconds)))\n"
            + "until [[ -e '\(path)' ]] || ((SECONDS >= stand_in_deadline)); do sleep 0.05; done"
    }

    /// A bare repo with one commit at `<dir>/remotes/<owner>/<name>.git`, to clone from.
    @discardableResult
    static func remote(in dir: TempDir, _ nameWithOwner: String) async throws -> String {
        let bare = dir.sub("remotes/\(nameWithOwner).git")
        let seed = try await repo(in: dir, name: "seed-\(UUID().uuidString.prefix(6))")
        try await git.run(["clone", "--quiet", "--bare", seed, bare])
        return Paths.canonical(bare)
    }

    /// A GitHubCLI whose gh clones `owner/repo` from `<dir>/remotes` and points origin at GitHub, as gh would.
    /// `before` runs first, with gh's arguments in "$@".
    static func cloningGH(in dir: TempDir, before: String = "", sshConfigFile: String? = nil) throws -> GitHubCLI {
        try gh(
            in: dir, sshConfigFile: sshConfigFile,
            """
            \(before)
            [[ "$1 $2" == "repo clone" ]] || exit 1
            repo="${3#https://github.com/}"
            repo="${repo%.git}"
            if [[ ! -d "\(dir.path)/remotes/$repo.git" ]]; then
                echo "GraphQL: Could not resolve to a Repository with the name '$repo'. (repository)" >&2
                exit 1
            fi
            '\(gitPath)' clone "${@:6}" "file://\(dir.path)/remotes/$repo.git" "$4" || exit 1
            '\(gitPath)' -C "$4" remote set-url origin "https://github.com/$repo.git"
            """)
    }

    /// A GitHubCLI that finds no gh.
    static func noGH(in dir: TempDir) -> GitHubCLI {
        GitHubCLI(environment: ["PATH": "/usr/bin:/bin", "HOME": dir.path], fallbackFolders: [])
    }

    /// A GitRunner that fetches https://github.com/ URLs from `<dir>/remotes` instead, so plain git clones of GitHub
    /// URLs stay on this machine.
    static func gitRedirectingGitHub(to dir: TempDir, executable: String = gitPath) -> GitRunner {
        var environment = Fixture.environment
        environment["GIT_CONFIG_COUNT"] = "1"
        environment["GIT_CONFIG_KEY_0"] = "url.file://\(dir.sub("remotes"))/.insteadOf"
        environment["GIT_CONFIG_VALUE_0"] = "https://github.com/"
        return GitRunner(executable: executable, environment: environment)
    }

    static func worktree(repo: String, branch: String, at path: String) async throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try await git.run(["worktree", "add", "--quiet", "-b", branch, path], in: repo)
    }
}

/// Runs blocking work (socket reads, lock waits) on its own thread. On a Swift concurrency thread it would
/// hold one of the few threads the server needs to answer it, and a small CI machine deadlocks.
func offPool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await onOwnThread { Result { try work() } }.get()
}

/// One test at a time takes every Dispatch thread, or two would each hold part of the pool and wait for the rest.
private let everyDispatchThreadGate = DispatchSemaphore(value: 1)

/// Runs `body` while blocks hold every thread Dispatch lends its global queues, as dozens of tests running git at once
/// did on a 3-CPU CI runner. `body` starts only once they all hold one: while Dispatch is still adding threads, it gives
/// the next to the most urgent work waiting, so work at a higher priority would slip through. Work queued meanwhile at
/// any priority waits until `body` returns, or ten seconds at most.
func withEveryDispatchThreadBusy<T>(_ body: () async throws -> T) async throws -> T {
    var threads: UInt32 = 0
    var size = MemoryLayout<UInt32>.size
    try #require(sysctlbyname("kern.wq_max_constrained_threads", &threads, &size, nil, 0) == 0)
    let limit = threads
    try await offPool { everyDispatchThreadGate.wait() }
    defer { everyDispatchThreadGate.signal() }
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let deadline = DispatchTime.now() + 10
    for _ in 0..<limit {
        DispatchQueue.global().async {
            started.signal()
            _ = release.wait(timeout: deadline)
        }
    }
    defer {
        for _ in 0..<limit { release.signal() }
    }
    let allStarted = try await offPool { (0..<limit).allSatisfy { _ in started.wait(timeout: deadline) == .success } }
    try #require(allStarted, "Dispatch never lent every thread, so the pool was never full")
    return try await body()
}

/// Polls until `condition` holds or the timeout passes. Returns whether it held. The timeout is long because a loaded CI
/// runner can take many seconds to start a process, and a condition that holds returns at once anyway.
/// The condition runs on the caller's actor, so main-actor tests can read main-actor state.
func eventually(
    timeout: Duration = .seconds(20),
    isolation: isolated (any Actor)? = #isolation,
    _ condition: () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return await condition()
}
