import ArgumentParser
import CanopyCore
import Foundation

struct CLIError: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}

struct OutputOptions: ParsableArguments {
    @Flag(help: "Print machine-readable JSON.")
    var json = false
}

/// Sends one request to the app, launching it first if it is not running.
struct Client {
    let home: CanopyHome
    let json: Bool

    init(json: Bool) {
        self.home = CanopyHome.resolve(bundleHome: AppLocator.bundleHome())
        self.json = json
    }

    func call(_ method: String, _ params: some Encodable, launchIfNeeded: Bool = true) throws -> JSONValue {
        let request = ControlRequest(method: method, params: try .from(params))
        let client = ControlClient(socketPath: home.socketPath)
        let response: ControlResponse
        do {
            response = try client.send(request)
        } catch let error as ControlClientError where error.isAppNotRunning && launchIfNeeded {
            try AppLocator.launch(home: home)
            response = try client.send(request)
        }
        if let error = response.error {
            fail(error)
        }
        return response.result ?? .null
    }

    /// Prints the raw result with --json, or the human summary otherwise.
    func print(_ result: JSONValue, human: () throws -> String) throws {
        if json {
            Swift.print(try Self.pretty(result))
        } else {
            Swift.print(try human())
        }
    }

    func fail(_ error: ControlError) -> Never {
        if json, let text = try? Self.pretty(.object(["error": try .from(error)])) {
            Swift.print(text)
        }
        FileHandle.standardError.write(Data("error: \(error.message)\n".utf8))
        Foundation.exit(1)
    }

    static func pretty(_ value: JSONValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// Everything the app needs to resolve repo and row arguments the way the user meant them.
    static func hint(repo: String? = nil, row: String? = nil) -> TargetHint {
        let environment = ProcessInfo.processInfo.environment
        return TargetHint(
            repo: repo.map(absolutePathIfRelative),
            row: row.map(absolutePathIfRelative),
            envRepo: environment["CANOPY_REPO"],
            envRowPath: environment["CANOPY_ROW_PATH"],
            cwd: FileManager.default.currentDirectoryPath
        )
    }

    /// The app runs in a different folder, so `.` and `../x` must be resolved here.
    static func absolutePathIfRelative(_ value: String) -> String {
        guard value.hasPrefix(".") else { return value }
        return URL(fileURLWithPath: value, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .standardizedFileURL.path
    }

    static func absolutePath(_ value: String) -> String {
        if value.hasPrefix("/") || value.hasPrefix("~") { return value }
        return URL(fileURLWithPath: value, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .standardizedFileURL.path
    }
}

enum AppLocator {
    /// The Canopy.app this CLI ships in, following the ~/.local/bin symlink. CANOPY_APP overrides it.
    static func appBundle() -> URL? {
        if let path = ProcessInfo.processInfo.environment["CANOPY_APP"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        guard var url = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        while url.path != "/" {
            if url.pathExtension == "app" { return url }
            url.deleteLastPathComponent()
        }
        return nil
    }

    static func bundleHome() -> String? {
        guard let app = appBundle() else { return nil }
        return Bundle(url: app)?.object(forInfoDictionaryKey: CanopyHome.infoPlistKey) as? String
    }

    static func launch(home: CanopyHome) throws {
        guard let app = appBundle() else {
            throw CLIError("Canopy is not running and Canopy.app was not found. Set CANOPY_APP to its path.")
        }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "-n", "--env", "\(CanopyHome.environmentKey)=\(home.root.path)", app.path]
        try open.run()
        open.waitUntilExit()
        guard open.terminationStatus == 0 else {
            throw CLIError("Could not launch \(app.path).")
        }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if ControlClient.canConnect(socketPath: home.socketPath) { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw CLIError("Launched \(app.path) but it did not open \(home.socketPath) within 10 seconds.")
    }
}

enum Table {
    /// Left-aligned columns separated by two spaces.
    static func render(_ header: [String], _ rows: [[String]]) -> String {
        let all = [header] + rows
        let widths = header.indices.map { column in all.map { $0[column].count }.max() ?? 0 }
        return all.map { cells in
            cells.enumerated().map { index, cell in
                index == cells.count - 1 ? cell : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
            }
            .joined(separator: "  ")
        }
        .joined(separator: "\n")
    }
}
