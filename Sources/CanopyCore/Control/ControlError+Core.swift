import Foundation

extension ControlError {
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
