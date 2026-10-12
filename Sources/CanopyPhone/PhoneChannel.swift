import Foundation

/// Opens connections to the Mac's phone listener.
public protocol PhoneTransport: Sendable {
    func connect(host: String, port: UInt16) async throws -> any PhoneChannel
}

/// One connection to the Mac: lines out, lines in. Lines have no newline at their end.
public protocol PhoneChannel: Sendable {
    func send(_ line: Data) async throws
    /// Each line the Mac sends, ending when the connection does. It has one reader.
    var lines: AsyncThrowingStream<Data, any Error> { get }
    func close()
}

public enum PhoneTransportError: Error, Equatable, Sendable {
    /// Something answered at the address, but nothing listens on the port.
    case refused
    /// Nothing answered in time.
    case timedOut
    /// The address could not be reached, such as a name that does not resolve.
    case unreachable(String)
    /// The connection is closed.
    case closed
}
