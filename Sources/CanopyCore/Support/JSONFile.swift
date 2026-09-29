import Foundation

public enum JSONFileError: Error, Sendable, Equatable {
    /// The file could not be read, or is not what the editor takes.
    case unreadable(String)
    case writeFailed(String)
}

/// A JSON file that people edit by hand too, changed in place. Keys keep their order and numbers their spelling, and a
/// change is written beside the file and renamed over it, so a reader never sees half a file.
struct JSONFile: Sendable {
    /// The file as named. It may be a symbolic link, which stays one.
    let url: URL
    /// Checks what was read, and says why it cannot be used.
    let validate: @Sendable (OrderedJSON) throws -> OrderedJSON
    /// The permissions a file this makes gets. A file that is there keeps its own.
    let newFileMode: Int

    /// The file's contents, or an empty object when it does not exist yet.
    func read() throws -> OrderedJSON {
        try parse(try contents(of: target))
    }

    /// Rewrites the file with `transform`'s result, unless it changed nothing. A file changed by someone else while
    /// this ran is read again and transformed again. Returns whether the file changed.
    @discardableResult
    func update(_ transform: (OrderedJSON) throws -> OrderedJSON) throws -> Bool {
        for _ in 0..<3 {
            let target = self.target
            let original = try contents(of: target)
            let json = try parse(original)
            let updated = try transform(json)
            guard updated != json else { return false }
            let newline = original.map { $0.last == 0x0A } ?? true
            let data = Data((updated.formatted() + (newline ? "\n" : "")).utf8)
            if try write(data, to: target, replacing: original) { return true }
        }
        throw JSONFileError.writeFailed("it kept changing while Canopy wrote it")
    }

    /// The file the name points to, following symbolic links, so a linked file is written and the link stays.
    private var target: URL {
        url.resolvingSymlinksInPath()
    }

    private func contents(of file: URL) throws -> Data? {
        do {
            return try Data(contentsOf: file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            throw JSONFileError.unreadable(error.localizedDescription)
        }
    }

    private func parse(_ data: Data?) throws -> OrderedJSON {
        guard let data else { return .object([]) }
        do {
            return try validate(try OrderedJSON.parse(data))
        } catch let error as OrderedJSONError {
            throw JSONFileError.unreadable(error.description)
        }
    }

    /// Writes beside the file and renames over it, unless the file no longer holds `original`. Returns whether it
    /// wrote.
    private func write(_ data: Data, to file: URL, replacing original: Data?) throws -> Bool {
        let manager = FileManager.default
        let folder = file.deletingLastPathComponent()
        let temporary = folder.appending(path: ".\(file.lastPathComponent).canopy-\(UUID().uuidString.prefix(8))")
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: temporary)
            let permissions = (try? manager.attributesOfItem(atPath: file.path))?[.posixPermissions] as? Int
            try manager.setAttributes([.posixPermissions: permissions ?? newFileMode], ofItemAtPath: temporary.path)
            guard try contents(of: file) == original else {
                try? manager.removeItem(at: temporary)
                return false
            }
            guard rename(temporary.path, file.path) == 0 else {
                throw CocoaError(
                    .fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
            }
            return true
        } catch let error as JSONFileError {
            try? manager.removeItem(at: temporary)
            throw error
        } catch {
            try? manager.removeItem(at: temporary)
            throw JSONFileError.writeFailed(error.localizedDescription)
        }
    }
}

extension OrderedJSON {
    /// The same JSON with its keys in `JSONValue`'s order, which is sorted, for values Canopy writes itself.
    public init(_ value: JSONValue) {
        switch value {
        case .null: self = .null
        case .bool(let bool): self = .bool(bool)
        case .number(let number):
            if number.rounded() == number, abs(number) < 9_007_199_254_740_992 {
                self = .number(String(Int(number)))
            } else {
                self = .number(String(number))
            }
        case .string(let string): self = .string(string)
        case .array(let items): self = .array(items.map(OrderedJSON.init))
        case .object(let members):
            self = .object(members.sorted { $0.key < $1.key }.map { Member($0.key, OrderedJSON($0.value)) })
        }
    }

    /// The JSON as Canopy reads it elsewhere. Numbers become doubles, and a repeated key keeps its last value.
    public var value: JSONValue {
        switch self {
        case .null: .null
        case .bool(let bool): .bool(bool)
        case .number(let number): .number(Double(number) ?? 0)
        case .string(let string): .string(string)
        case .array(let items): .array(items.map(\.value))
        case .object(let members):
            .object(Dictionary(members.map { ($0.key, $0.value.value) }, uniquingKeysWith: { _, last in last }))
        }
    }
}
