import Foundation

public struct ControlError: Error, Codable, Sendable, Equatable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public init(_ error: WorkspaceError) {
        self.init(code: error.code, message: error.message)
    }

    /// Failures on the CLI's side of the socket, in the same shape as the app's own errors.
    public init(_ error: ControlClientError) {
        let code =
            switch error {
            case .socketPathTooLong: "socket_path_too_long"
            case .connectFailed where error.isAppNotRunning: "app_unavailable"
            case .connectFailed: "connect_failed"
            case .writeFailed, .connectionClosed: "connection_closed"
            case .timedOut: "timeout"
            }
        self.init(code: code, message: error.description)
    }
}

public struct ControlRequest: Codable, Sendable, Equatable {
    public var v: Int
    public var id: String
    public var method: String
    public var params: JSONValue?

    public init(method: String, params: JSONValue? = nil, id: String = UUID().uuidString, v: Int = ControlCodec.version)
    {
        self.v = v
        self.id = id
        self.method = method
        self.params = params
    }

    public func decodeParams<T: Decodable>(_ type: T.Type) throws -> T {
        do {
            return try (params ?? .object([:])).decode(type)
        } catch {
            throw ControlError(code: "bad_params", message: "Invalid params for \(method): \(error)")
        }
    }
}

public struct ControlResponse: Codable, Sendable, Equatable {
    public var v: Int
    public var id: String
    public var result: JSONValue?
    public var error: ControlError?

    public static func success(id: String, result: JSONValue) -> ControlResponse {
        ControlResponse(v: ControlCodec.version, id: id, result: result, error: nil)
    }

    public static func failure(id: String, error: ControlError) -> ControlResponse {
        ControlResponse(v: ControlCodec.version, id: id, result: nil, error: error)
    }
}

/// Newline-delimited JSON. Compact JSON never contains a raw newline, so one message is one line.
public enum ControlCodec {
    public static let version = 1

    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
        try JSONDecoder().decode(type, from: line)
    }
}
