import CanopyWire
import Foundation
import Observation

/// Starts boxes that powered themselves off, with the key each box handed over, and connects once Canopy there
/// answers. Only a tap wakes a box, never the app opening.
@MainActor @Observable
public final class Waker {
    public enum Step: Equatable, Sendable {
        /// Asking EC2 to start the instance, since `since`.
        case starting(since: Date)
        /// The instance is starting; the phone waits for Canopy on it to answer.
        case connecting(startedAt: Date)
        /// It went wrong at the step the problem names.
        case failed(PhoneProblem)
    }

    /// A box's card in the Inbox: off, waking, or what went wrong.
    public struct Card: Identifiable {
        public let server: ServerConnection
        /// Nil while the box is simply out of reach and nothing was tried.
        public var step: Step?

        public var id: String { server.id }
    }

    /// Each box's wake under way or that failed, by server id.
    public private(set) var steps: [String: Step] = [:]

    /// How often EC2 is asked again while the instance is still stopping, and for how long.
    static let stoppingEvery = Duration.seconds(10)
    static let stoppingFor: TimeInterval = 120
    /// How often the box's connection is tried again once it is starting, and for how long.
    static let connectEvery = Duration.seconds(10)
    static let connectFor: TimeInterval = 300

    private let http: any HTTPPosting
    private let endpoint: @Sendable (String) -> URL
    private let sleep: Sleep
    private let now: @Sendable () -> Date

    public init(
        http: any HTTPPosting = URLSessionPoster(), endpoint: @escaping @Sendable (String) -> URL = EC2Start.endpoint,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }, now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.http = http
        self.endpoint = endpoint
        self.sleep = sleep
        self.now = now
    }

    /// The cards the Inbox shows: a box with a wake key that is out of reach, or whose wake is under way or failed.
    /// One that answers has none, even before its wake notices.
    public func cards(for servers: Servers) -> [Card] {
        servers.paired.compactMap { server in
            let step = steps[server.id]
            guard server.isBox, server.server.wake != nil, !server.isConnected, step != nil || server.isUnreachable
            else { return nil }
            return Card(server: server, step: step)
        }
    }

    public func isWaking(_ server: ServerConnection) -> Bool {
        switch steps[server.id] {
        case .starting, .connecting: true
        case .failed, nil: false
        }
    }

    /// Starts the box's instance, then waits for Canopy on it to answer. A tap while a wake is under way does nothing.
    public func wake(_ server: ServerConnection) async {
        guard let wake = server.server.wake, !isWaking(server) else { return }
        let id = server.id
        let started = now()
        steps[id] = .starting(since: started)
        while true {
            let answer: EC2Start.Answer
            let url = endpoint(wake.region)
            let request = EC2Start.request(wake, endpoint: url, date: now())
            do {
                let reply = try await http.post(url, headers: request.headers, body: request.body)
                answer = EC2Start.answer(status: reply.status, body: reply.body)
            } catch {
                answer = .failed(error.localizedDescription)
            }
            switch answer {
            case .starting:
                await connect(server, startedAt: now())
                return
            case .stillStopping where now().timeIntervalSince(started) < Self.stoppingFor:
                guard (try? await sleep(Self.stoppingEvery)) != nil else {
                    return fail(id, Self.didNotStart(server, ""))
                }
            case .stillStopping:
                return fail(id, Self.didNotStart(server, "It was still stopping after 2 minutes."))
            case .refused(let message):
                return fail(
                    id,
                    PhoneProblem(
                        title: "AWS refused \(server.name)'s wake key.",
                        detail: "\(message) Set a new key with canopy host wake-key \(server.name) on the Mac."))
            case .failed(let message):
                return fail(id, Self.didNotStart(server, message))
            }
        }
    }

    /// Tries the box's connection now and every 10 seconds, until it answers or 5 minutes pass.
    private func connect(_ server: ServerConnection, startedAt: Date) async {
        steps[server.id] = .connecting(startedAt: startedAt)
        while now().timeIntervalSince(startedAt) < Self.connectFor {
            if server.isConnected {
                steps[server.id] = nil
                return
            }
            server.foreground()
            guard (try? await sleep(Self.connectEvery)) != nil else { break }
        }
        if server.isConnected {
            steps[server.id] = nil
        } else {
            fail(
                server.id,
                PhoneProblem(
                    title: "\(server.name) started, and Canopy on it did not answer.",
                    detail: "Check that canopy-box runs there, and that Tailscale is up on it."))
        }
    }

    private func fail(_ id: String, _ problem: PhoneProblem) {
        steps[id] = .failed(problem)
    }

    private static func didNotStart(_ server: ServerConnection, _ message: String) -> PhoneProblem {
        PhoneProblem(title: "\(server.name)'s instance did not start.", detail: message)
    }
}
