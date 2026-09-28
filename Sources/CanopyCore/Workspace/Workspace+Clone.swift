import Foundation
import Synchronization

extension Workspace {
    /// Clones a repo into CANOPY_HOME/repos/<owner>/<name>, or into `folder`, and registers it. A folder that already
    /// holds a clone of the same repo is registered as it is. Clones of one folder run one at a time, so a second clone
    /// of a repo finds the first one's folder. Cancelling the calling task stops the clone and deletes what it wrote.
    @discardableResult
    public func cloneRepo(
        _ text: String, into folder: String? = nil,
        progress: @escaping @Sendable (CloneProgress) -> Void = { _ in }
    ) async throws -> RepoSnapshot {
        let source = try CloneSource(text)
        let destination = Paths.canonical(try folder ?? source.defaultFolder(in: home))
        let handle = SubprocessHandle()
        return try await withTaskCancellationHandler {
            try await serialized(repoPath: destination) {
                try await self.clone(source, to: destination, handle: handle, progress: progress)
            }
        } onCancel: {
            handle.cancel()
        }
    }

    /// Stops every clone under way and deletes what they wrote, without waiting, for quitting.
    public nonisolated func stopClones() {
        runningClones.stopAll()
    }

    /// Clones into a hidden folder beside the destination and renames it into place once git is done, so the
    /// destination only ever holds a whole clone.
    private func clone(
        _ source: CloneSource, to destination: String, handle: SubprocessHandle,
        progress: @escaping @Sendable (CloneProgress) -> Void
    ) async throws -> RepoSnapshot {
        guard !handle.isCancelled else { throw WorkspaceError.cloneCancelled }
        if try await holdsClone(of: source, at: destination) {
            return try await addRepo(path: destination)
        }
        let parent = (destination as NSString).deletingLastPathComponent
        let created: [String]
        do {
            created = try Self.createFolders(parent)
        } catch {
            throw WorkspaceError.cloneFailed(source.text, reason: error.localizedDescription)
        }
        let staging =
            "\(parent)/.\((destination as NSString).lastPathComponent).canopy-clone-\(UUID().uuidString.prefix(8))"
        runningClones.add(handle, folder: staging, created: created)
        defer { runningClones.remove(handle) }
        do {
            try await fetch(source, into: staging, handle: handle, progress: progress)
            guard !handle.isCancelled else { throw WorkspaceError.cloneCancelled }
            // rename(2) replaces an empty folder and refuses a full one.
            if rename(staging, destination) != 0 {
                let reason = String(cString: strerror(errno))
                try? FileManager.default.removeItem(atPath: staging)
                if try await holdsClone(of: source, at: destination) {
                    return try await addRepo(path: destination)
                }
                throw WorkspaceError.cloneFailed(source.text, reason: reason)
            }
        } catch {
            RunningClones.delete(staging, created: created)
            throw handle.isCancelled ? WorkspaceError.cloneCancelled : error
        }
        return try await addRepo(path: destination, clonedFrom: source.text)
    }

    /// gh for GitHub repos, since it knows the user's login and preferred protocol. Plain git for other URLs, and for
    /// GitHub URLs when gh cannot be used.
    private func fetch(
        _ source: CloneSource, into folder: String, handle: SubprocessHandle,
        progress: @escaping @Sendable (CloneProgress) -> Void
    ) async throws {
        let watcher = Task.detached {
            var last: CloneProgress?
            while !Task.isCancelled {
                if let now = CloneProgress.latest(in: handle.errorOutput()), now != last {
                    last = now
                    progress(now)
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { watcher.cancel() }

        if let argument = source.ghArgument, let repo = source.github {
            let fix: String
            switch await github.clone(argument, into: folder, handle: handle) {
            case nil: return
            case .failed(let reason)?: throw WorkspaceError.cloneFailed(source.text, reason: reason)
            case .ghMissing?:
                fix =
                    "Install gh to clone \(repo.nameWithOwner): `brew install gh`, then `gh auth login`. Or pass the repo's URL."
            case .notLoggedIn?:
                fix = "Run `gh auth login` to clone \(repo.nameWithOwner), or pass the repo's URL."
            }
            guard source.url != nil else { throw WorkspaceError.ghUnavailable(fix) }
            try? FileManager.default.removeItem(atPath: folder)
        }
        guard let url = source.url else { return }
        do {
            try await git.run(["clone", "--progress", "--", url, folder], handle: handle)
        } catch let error as GitError {
            throw WorkspaceError.cloneFailed(source.text, reason: ToolOutput.reason(error.stderr) ?? error.description)
        }
    }

    /// Whether `folder` already holds a clone of `source`. False when it is missing or empty, so a clone can go there.
    /// Throws `folderTaken` for anything else.
    private func holdsClone(of source: CloneSource, at folder: String) async throws -> Bool {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder) else { return false }
        guard isFolder.boolValue else { throw WorkspaceError.folderTaken(folder, holding: nil) }
        if (try? FileManager.default.contentsOfDirectory(atPath: folder))?.isEmpty == true { return false }
        let top = try? await git.run(["rev-parse", "--show-toplevel"], in: folder)
        guard let top, Paths.canonical(top.trimmingCharacters(in: .whitespacesAndNewlines)) == folder else {
            throw WorkspaceError.folderTaken(folder, holding: nil)
        }
        // The URL as saved, and as git would use it after `insteadOf` rules, since either may name the repo.
        var origins: [String] = []
        for arguments in [["config", "--get", "remote.origin.url"], ["remote", "get-url", "origin"]] {
            let origin = (try? await git.run(arguments, in: folder))?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let origin, !origin.isEmpty, !origins.contains(origin) { origins.append(origin) }
        }
        guard let first = origins.first else {
            throw WorkspaceError.folderTaken(folder, holding: "a repo with no origin")
        }
        for origin in origins {
            if source.isSameRepo(asOrigin: origin, gitHubRepo: await github.repo(forRemote: origin)) { return true }
        }
        throw WorkspaceError.folderTaken(folder, holding: "a clone of \(first)")
    }

    /// Creates `path` and any folders above it, and returns the ones it created, outermost first.
    private static func createFolders(_ path: String) throws -> [String] {
        var missing: [String] = []
        var current = path
        while !FileManager.default.fileExists(atPath: current), current != "/" {
            missing.insert(current, at: 0)
            current = (current as NSString).deletingLastPathComponent
        }
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return missing
    }
}

/// Clones under way, with the hidden folder each writes to and the folders it created to hold it.
final class RunningClones: Sendable {
    private struct Clone {
        let handle: SubprocessHandle
        let folder: String
        let created: [String]
    }

    private let clones = Mutex<[ObjectIdentifier: Clone]>([:])

    func add(_ handle: SubprocessHandle, folder: String, created: [String]) {
        clones.withLock { $0[ObjectIdentifier(handle)] = Clone(handle: handle, folder: folder, created: created) }
    }

    func remove(_ handle: SubprocessHandle) {
        _ = clones.withLock { $0.removeValue(forKey: ObjectIdentifier(handle)) }
    }

    func stopAll() {
        let stopping = clones.withLock { clones in
            defer { clones.removeAll() }
            return Array(clones.values)
        }
        for clone in stopping {
            clone.handle.cancel()
            Self.delete(clone.folder, created: clone.created)
        }
    }

    /// Deletes a clone's hidden folder, then the folders it created to hold it, innermost first, while they are empty.
    static func delete(_ folder: String, created: [String]) {
        try? FileManager.default.removeItem(atPath: folder)
        for path in created.reversed() {
            guard rmdir(path) == 0 else { return }
        }
    }
}
