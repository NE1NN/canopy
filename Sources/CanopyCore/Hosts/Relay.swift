import Foundation

public enum RelayPaths {
    /// The Mac folder for a host's `remote` folder: the stand-in of the remote row holding it, with the same tail.
    /// Anything else becomes `home`, so the CLI targets nothing by folder and never reads a host path as a Mac one.
    public static func local(_ remote: String, rows: [RemoteRowEntry], home: String) -> String {
        guard let components = components(remote) else { return home }
        var best: (row: RemoteRowEntry, depth: Int)?
        for row in rows {
            guard let root = Self.components(row.path), !root.isEmpty, components.starts(with: root),
                root.count > best?.depth ?? 0
            else { continue }
            best = (row, root.count)
        }
        guard let best else { return home }
        let tail = components.dropFirst(best.depth)
        return tail.isEmpty ? best.row.standIn : best.row.standIn + "/" + tail.joined(separator: "/")
    }

    /// An absolute path's components, or nil for a relative path or one with `..`, whose tail could leave the stand-in.
    static func components(_ path: String) -> [Substring]? {
        guard path.hasPrefix("/") else { return nil }
        let components = path.split(separator: "/").filter { $0 != "." }
        return components.contains("..") ? nil : components
    }
}

public enum RelayRun {
    /// The host a CLI run came from through its relay, from the `CANOPY_HOST` that `environment(for:)` sets.
    /// A local pane never has it.
    public static func host(in environment: [String: String]) -> String? {
        environment["CANOPY_HOST"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The variables the CLI reads from the pane it runs in, the only ones of a request that cross over. Others would
    /// mislead or steer the CLI on this Mac by what a program on the host chose: the host's PATH or HOME, or
    /// `CANOPY_APP`, `CANOPY_SSH`, and `CANOPY_SOCKET`.
    public static let paneVariables: Set<String> = [
        "CANOPY_PANE", "CANOPY_REPO", "CANOPY_ROW_PATH", "CANOPY_PLUGIN", "CANOPY_ITEM",
    ]

    /// The environment for the app's CLI running a host's request: the request's `paneVariables`, this Mac's PATH,
    /// HOME, and TMPDIR, and the home, host, and time the app sets.
    public static func environment(
        for request: RelayRequest, host: String, rows: [RemoteRowEntry], home: CanopyHome, receivedAt: Date,
        shellEnvironment: [String: String] = GitEnvironment.current
    ) -> [String: String] {
        var environment = request.env.filter { paneVariables.contains($0.key) }
        environment[CanopyHome.environmentKey] = home.root.path
        environment["CANOPY_HOST"] = host
        if let rowPath = environment["CANOPY_ROW_PATH"] {
            let hostRows = rows.filter { $0.host == host }
            environment["CANOPY_ROW_PATH"] = RelayPaths.local(rowPath, rows: hostRows, home: home.root.path)
        }
        if let age = request.age, age.isFinite, age >= 0 {
            environment["CANOPY_STARTED_AT"] = String(receivedAt.timeIntervalSince1970 - age)
        }
        for key in ["PATH", "HOME", "TMPDIR"] {
            environment[key] = shellEnvironment[key]
        }
        return environment
    }

    /// The folder the app's CLI runs a host's request in: the request's, translated, or the nearest folder above it
    /// in the same stand-in, since a stand-in holds only what Canopy put there. Without one, the home.
    public static func folder(for request: RelayRequest, host: String, rows: [RemoteRowEntry], home: CanopyHome)
        -> String
    {
        let rows = rows.filter { $0.host == host }
        var folder = RelayPaths.local(request.cwd, rows: rows, home: home.root.path)
        let standIn = rows.map(\.standIn).filter { folder == $0 || folder.hasPrefix($0 + "/") }
            .max { $0.count < $1.count }
        guard let standIn else { return home.root.path }
        var isFolder: ObjCBool = false
        while folder.count >= standIn.count {
            if FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder), isFolder.boolValue {
                return folder
            }
            folder = (folder as NSString).deletingLastPathComponent
        }
        return home.root.path
    }
}
