import CanopyWire
import Foundation
import Synchronization
import Testing

@testable import CanopyPhone

struct SigV4Tests {
    static let secret = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"

    static func date(_ stamp: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
        return formatter.date(from: stamp)!
    }

    static func signature(_ headers: [String: String]) -> String? {
        headers["Authorization"]?.components(separatedBy: "Signature=").last
    }

    /// AWS's own `get-vanilla` example from its Signature Version 4 test suite.
    @Test func signsAWSsExample() {
        let signer = SigV4(
            accessKeyID: "AKIDEXAMPLE", secretAccessKey: Self.secret, region: "us-east-1", service: "service")

        let headers = signer.sign(
            method: "GET", url: URL(string: "https://example.amazonaws.com/")!, date: Self.date("20150830T123600Z"))

        #expect(Self.signature(headers) == "5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
        #expect(
            headers["Authorization"]?.hasPrefix(
                "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date,"
            ) == true)
    }

    /// Checked against an independent implementation of the same algorithm, which also gives `get-vanilla`'s.
    @Test func signsStartInstances() {
        let wake = PhoneWake(
            accessKeyID: "AKIDEXAMPLE", secretAccessKey: Self.secret, instanceID: "i-069bf8c49e5f996ab",
            region: "ap-southeast-2")

        let request = EC2Start.request(
            wake, endpoint: EC2Start.endpoint(region: "ap-southeast-2"), date: Self.date("20261014T010203Z"))

        #expect(
            String(decoding: request.body, as: UTF8.self)
                == "Action=StartInstances&InstanceId.1=i-069bf8c49e5f996ab&Version=2016-11-15")
        #expect(request.headers["Host"] == "ec2.ap-southeast-2.amazonaws.com")
        #expect(Self.signature(request.headers) == "fb898fe75e27a0cef0caabd13093d2ab30d0f8ff8fdad6c7e5f0a93867c43e7b")
    }

    @Test func readsWhatEC2Answers() {
        func answer(_ status: Int, _ body: String) -> EC2Start.Answer {
            EC2Start.answer(status: status, body: Data(body.utf8))
        }
        let started =
            "<StartInstancesResponse><instancesSet><item><currentState><code>0</code><name>pending</name></currentState><previousState><name>stopped</name></previousState></item></instancesSet></StartInstancesResponse>"
        #expect(answer(200, started) == .starting)
        #expect(answer(400, FakeEC2.error("IncorrectInstanceState", "stopping")) == .stillStopping)
        #expect(
            answer(401, FakeEC2.error("AuthFailure", "AWS was not able to validate."))
                == .refused("AWS was not able to validate."))
        #expect(
            answer(400, FakeEC2.error("InvalidInstanceID.NotFound", "No such instance."))
                == .failed("No such instance."))
        #expect(answer(503, "") == .failed("HTTP 503"))
        #expect(answer(400, FakeEC2.error("RequestExpired", "Request has expired.")) == .clockWrong)
        #expect(
            answer(200, "<StartInstancesResponse/>")
                == .failed("EC2 answered without saying what the instance is doing."))
    }
}

/// EC2's endpoint: each `StartInstances` gets the next answer, then the last one again.
final class FakeEC2: HTTPPosting, Sendable {
    let answers: Mutex<[(Int, String)]>
    let posts = Mutex<[(URL, [String: String], Data)]>([])
    let onPost: @Sendable () -> Void

    init(_ answers: [(Int, String)], onPost: @escaping @Sendable () -> Void = {}) {
        self.answers = Mutex(answers)
        self.onPost = onPost
    }

    static let pending = (
        200,
        "<StartInstancesResponse><instancesSet><item><currentState><name>pending</name></currentState></item></instancesSet></StartInstancesResponse>"
    )

    static func error(_ code: String, _ message: String) -> String {
        "<Response><Errors><Error><Code>\(code)</Code><Message>\(message)</Message></Error></Errors></Response>"
    }

    var count: Int { posts.withLock { $0.count } }

    func post(_ url: URL, headers: [String: String], body: Data) async throws -> (status: Int, body: Data) {
        posts.withLock { $0.append((url, headers, body)) }
        onPost()
        let next = answers.withLock { list in list.count > 1 ? list.removeFirst() : list[0] }
        return (next.0, Data(next.1.utf8))
    }
}

@MainActor
struct WakerTests {
    let box = FakeMac.box()
    /// The box's connection's backoff.
    let sleeper = ManualSleeper()
    /// The waker's own waits.
    let waits = ManualSleeper()
    static let wake = PhoneWake(
        accessKeyID: "AKIA", secretAccessKey: "s", instanceID: "i-0123", region: "ap-southeast-2")

    /// A paired box that has handed over its key, then went away.
    func offBox() async throws -> (Servers, ServerConnection) {
        box.state.withLock { $0.wake = Self.wake }
        let servers = try await servers(box, sleeper: sleeper)
        let connection = try #require(servers.connections.first)
        #expect(connection.server.wake == Self.wake)
        box.goAway()
        #expect(await eventually { connection.isUnreachable })
        return (servers, connection)
    }

    func waker(_ ec2: FakeEC2) -> Waker {
        Waker(http: ec2, endpoint: { URL(string: "https://ec2.\($0).test/")! }, sleep: waits.sleep)
    }

    @Test func helloCarriesTheWakeKeyAndItsClearing() async throws {
        let (servers, connection) = try await offBox()
        let waker = waker(FakeEC2([FakeEC2.pending]))
        #expect(waker.cards(for: servers).map(\.server.id) == [connection.id])

        box.state.withLock { $0.wake = nil }
        box.comeBack()
        servers.foreground()

        #expect(await eventually { connection.isConnected && connection.server.wake == nil })
        box.goAway()
        #expect(await eventually { connection.isUnreachable })
        #expect(waker.cards(for: servers).isEmpty)
    }

    @Test func aTapStartsTheInstanceAndConnectsOnceItAnswers() async throws {
        let (servers, connection) = try await offBox()
        let box = box
        let ec2 = FakeEC2([FakeEC2.pending]) { box.comeBack() }
        let waker = waker(ec2)

        let waking = Task { await waker.wake(connection) }
        #expect(await eventually { connection.isConnected })
        #expect(waker.cards(for: servers).isEmpty)
        await waits.wake()
        await waking.value

        #expect(ec2.count == 1)
        let post = try #require(ec2.posts.withLock { $0.first })
        #expect(post.0.absoluteString == "https://ec2.ap-southeast-2.test/")
        #expect(post.1["Authorization"]?.contains("Credential=AKIA/") == true)
        #expect(waker.steps[connection.id] == nil)
    }

    @Test func aStoppingInstanceIsAskedAgain() async throws {
        let (_, connection) = try await offBox()
        let box = box
        let ec2 = FakeEC2([(400, FakeEC2.error("IncorrectInstanceState", "stopping")), FakeEC2.pending]) {}
        let waker = waker(ec2)

        let waking = Task { await waker.wake(connection) }
        #expect(await eventually { ec2.count == 1 && waits.sleeping == 1 })
        #expect(waits.durations.last == Waker.stoppingEvery)
        guard case .starting = waker.steps[connection.id] else {
            Issue.record("not starting")
            return
        }
        box.comeBack()
        await waits.wake()
        #expect(await eventually { ec2.count == 2 })
        #expect(await eventually { connection.isConnected })
        await waits.wake()
        await waking.value
        #expect(waker.steps[connection.id] == nil)
    }

    @Test func aRefusedKeySaysSo() async throws {
        let (servers, connection) = try await offBox()
        let waker = waker(
            FakeEC2([(401, FakeEC2.error("AuthFailure", "AWS was not able to validate the credentials."))]))

        await waker.wake(connection)

        guard case .failed(let problem) = waker.steps[connection.id] else {
            Issue.record("no failure")
            return
        }
        #expect(problem.title == "AWS refused hindie-box's wake key.")
        #expect(problem.detail.contains("canopy host wake-key hindie-box"))
        #expect(waker.cards(for: servers).first?.step == .failed(problem))
    }

    @Test func anInstanceThatNeverStartsSaysSo() async throws {
        let (_, connection) = try await offBox()
        let waker = waker(FakeEC2([(400, FakeEC2.error("InvalidInstanceID.NotFound", "No such instance."))]))

        await waker.wake(connection)

        #expect(
            waker.steps[connection.id]
                == .failed(PhoneProblem(title: "hindie-box's instance did not start.", detail: "No such instance.")))
    }

    @Test func aStartedBoxThatNeverAnswersSaysSo() async throws {
        let (_, connection) = try await offBox()
        let clock = Mutex(Date())
        let waker = Waker(
            http: FakeEC2([FakeEC2.pending]), endpoint: { _ in URL(string: "https://ec2.test/")! },
            sleep: { duration in clock.withLock { $0 += TimeInterval(duration.components.seconds) } },
            now: { clock.withLock { $0 } })

        await waker.wake(connection)

        guard case .failed(let problem) = waker.steps[connection.id] else {
            Issue.record("no failure")
            return
        }
        #expect(problem.title == "hindie-box started, and Canopy on it did not answer.")
    }

    @Test func anInstanceStillStoppingAfterTwoMinutesSaysSo() async throws {
        let (_, connection) = try await offBox()
        let clock = Mutex(Date())
        let waker = Waker(
            http: FakeEC2([(400, FakeEC2.error("IncorrectInstanceState", "stopping"))]),
            endpoint: { _ in URL(string: "https://ec2.test/")! },
            sleep: { duration in clock.withLock { $0 += TimeInterval(duration.components.seconds) } },
            now: { clock.withLock { $0 } })

        await waker.wake(connection)

        #expect(
            waker.steps[connection.id]
                == .failed(
                    PhoneProblem(
                        title: "hindie-box's instance did not start.", detail: "It was still stopping after 2 minutes.")
                ))
    }

    /// A failure shows until the box connects again, then no more, so a later power-off shows the box as off.
    @Test func aFailureGoesOnceTheBoxConnects() async throws {
        let (servers, connection) = try await offBox()
        let waker = waker(FakeEC2([(400, FakeEC2.error("InvalidInstanceID.NotFound", "No such instance."))]))
        await waker.wake(connection)
        guard case .failed = waker.cards(for: servers).first?.step else {
            Issue.record("no failed card")
            return
        }

        box.comeBack()
        servers.foreground()
        #expect(await eventually { connection.isConnected })
        box.goAway()
        #expect(await eventually { connection.isUnreachable })

        #expect(waker.cards(for: servers).map(\.step) == [nil])
    }

    /// A box that forgot the phone takes its key away, so the phone can no longer start it.
    @Test func aForgottenBoxLeavesNoKey() async throws {
        let (servers, connection) = try await offBox()
        box.comeBack()
        servers.foreground()
        #expect(await eventually { connection.isConnected })

        box.forget(phone: "iPhone")
        box.dropAll()

        #expect(await eventually { !connection.isPaired })
        #expect(connection.server.wake == nil)
    }

    @Test func aSecondTapWhileWakingDoesNothing() async throws {
        let (_, connection) = try await offBox()
        let ec2 = FakeEC2([(400, FakeEC2.error("IncorrectInstanceState", "stopping"))])
        let waker = waker(ec2)
        let first = Task { await waker.wake(connection) }
        #expect(await eventually { ec2.count == 1 && waits.sleeping == 1 })

        await waker.wake(connection)

        #expect(ec2.count == 1)
        first.cancel()
        await first.value
    }
}
