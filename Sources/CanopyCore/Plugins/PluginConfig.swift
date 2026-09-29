import Foundation

/// Which plugins config.json turns on, and what each one's section of it holds.
public enum PluginConfig {
    /// Each plugin's section of config.json's `plugins`. A missing file, or one without `plugins`, has none.
    public static func sections(in file: URL) throws -> [String: JSONValue] {
        let json = try PluginConfigFile(url: file).read()
        guard case .object(let plugins)? = json["plugins"]?.value else { return [:] }
        return plugins
    }

    /// On while the section is there and does not say `"enabled": false`.
    public static func isOn(_ section: JSONValue?) -> Bool {
        guard let section else { return false }
        if case .object(let fields) = section, fields["enabled"] == .bool(false) { return false }
        return true
    }
}

/// config.json as `plugin.enable` and `plugin.disable` write it: only the plugin's own section changes.
public struct PluginConfigFile: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    func read() throws -> OrderedJSON {
        try configErrors { try file.read() }
    }

    /// Merges `fields` into the plugin's section, takes out `"enabled": false`, and returns the section as written.
    /// A section that is not an object becomes one.
    @discardableResult
    public func enable(_ plugin: String, fields: [String: JSONValue]) throws -> JSONValue {
        try change(plugin) { section in
            for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
                section[key] = OrderedJSON(value)
            }
            section["enabled"] = nil
        }
    }

    /// Sets `"enabled": false` in the plugin's section, keeping the rest of it, and returns the section as written.
    @discardableResult
    public func disable(_ plugin: String) throws -> JSONValue {
        try change(plugin) { $0["enabled"] = .bool(false) }
    }

    private func change(_ plugin: String, _ edit: (inout OrderedJSON) -> Void) throws -> JSONValue {
        var written = JSONValue.object([:])
        _ = try configErrors {
            try file.update { json in
                var json = json
                var plugins = Self.object(json["plugins"])
                var section = Self.object(plugins[plugin])
                edit(&section)
                written = section.value
                plugins[plugin] = section
                json["plugins"] = plugins
                return json
            }
        }
        return written
    }

    /// The value when it is an object, or an empty one in its place.
    private static func object(_ json: OrderedJSON?) -> OrderedJSON {
        guard let json, case .object = json else { return .object([]) }
        return json
    }

    /// It sits in the private home folder, and a file Canopy makes there is for this user alone.
    private var file: JSONFile {
        JSONFile(
            url: url,
            validate: { json in
                guard case .object = json else {
                    throw OrderedJSONError(offset: 0, reason: "The settings are not a JSON object")
                }
                return json
            }, newFileMode: 0o600)
    }

    private func configErrors<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch JSONFileError.unreadable(let reason) {
            throw WorkspaceError.configInvalid(url.path, reason: reason)
        } catch JSONFileError.writeFailed(let reason) {
            throw WorkspaceError.configWriteFailed(url.path, reason: reason)
        }
    }
}
