import Foundation

/// Claude Code's folder trust, which headless Claude Code does not ask for, so a chat asks itself.
/// Claude Code keeps it in `~/.claude.json` as `projects[<path>].hasTrustDialogAccepted`. As checked against its TUI
/// (2.1.296): in a git repo, the repo's main checkout or the folder itself counts and accepting writes the main
/// checkout; outside git, the folder or any folder above it counts and accepting writes the folder.
public enum ClaudeTrust {
    public enum Place: Equatable, Sendable {
        /// A worktree row and its repo's main checkout.
        case row(path: String, repo: String)
        /// A folder outside git, such as a plugin row's.
        case folder(String)

        var candidates: [String] {
            switch self {
            case .row(let path, let repo):
                return [path, repo]
            case .folder(let path):
                var folders: [String] = []
                var current = path
                while true {
                    folders.append(current)
                    let parent = (current as NSString).deletingLastPathComponent
                    if parent == current || parent.isEmpty { return folders }
                    current = parent
                }
            }
        }

        var key: String {
            switch self {
            case .row(_, let repo): repo
            case .folder(let path): path
            }
        }
    }

    public enum Failure: Error, Equatable, Sendable {
        /// The file is there but is not JSON Canopy can read, so it is left alone.
        case unreadable
        /// Another Claude Code wrote over the change every time.
        case notKept
        case notWritten(String)
    }

    /// Where Claude Code keeps it for a home folder.
    public static func config(home: String) -> URL {
        URL(fileURLWithPath: home).appending(path: ".claude.json")
    }

    public static func isTrusted(_ place: Place, config: URL) -> Bool {
        guard let projects = (try? load(config))?["projects"]?.fields else { return false }
        return place.candidates.contains { projects[$0]?.fields?["hasTrustDialogAccepted"]?.flag == true }
    }

    /// Writes the trust, then checks it is still there after `settle`, writing again up to three times.
    /// `written` runs after each write, for tests.
    public static func trust(
        _ place: Place, config: URL, settle: Duration = .milliseconds(300), written: () -> Void = {}
    ) throws {
        for _ in 0..<3 {
            var object: [String: JSONValue]
            do {
                object = try load(config) ?? [:]
            } catch {
                throw Failure.unreadable
            }
            var projects = object["projects"]?.fields ?? [:]
            var settings = projects[place.key]?.fields ?? [:]
            settings["hasTrustDialogAccepted"] = .bool(true)
            projects[place.key] = .object(settings)
            object["projects"] = .object(projects)
            try save(object, to: config)
            written()
            Thread.sleep(forTimeInterval: settle / .seconds(1))
            if isTrusted(place, config: config) { return }
        }
        throw Failure.notKept
    }

    /// Nil when there is no file.
    private static func load(_ config: URL) throws -> [String: JSONValue]? {
        guard let data = try? Data(contentsOf: config) else { return nil }
        return try JSONDecoder().decode([String: JSONValue].self, from: data)
    }

    private static func save(_ object: [String: JSONValue], to link: URL) throws {
        // A file kept elsewhere through a symlink is replaced where it is, leaving the link.
        let config = link.resolvingSymlinksInPath()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(JSONValue.object(object))
            let temporary = config.deletingLastPathComponent().appending(
                path: ".claude.json.canopy-\(UUID().uuidString)")
            guard
                FileManager.default.createFile(
                    atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600])
            else { throw Failure.notWritten("could not write \(temporary.path)") }
            guard rename(temporary.path, config.path) == 0 else {
                let reason = String(cString: strerror(errno))
                try? FileManager.default.removeItem(at: temporary)
                throw Failure.notWritten(reason)
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.notWritten("\(error)")
        }
    }
}
