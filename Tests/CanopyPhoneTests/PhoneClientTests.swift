import CanopyWire
import Foundation
import Testing

@testable import CanopyPhone

struct PhoneClientTests {
    @Test func aCallGetsItsOwnResponseWhenAnothersComesFirst() async throws {
        let channel = PipeChannel()
        let client = PhoneClient(channel: channel)
        async let rows = client.call(PhoneMethod.rows, as: PhoneRowsResult.self)
        async let seen = client.call(PhoneMethod.seen, PhonePaneParams(pane: "p1"), as: PhonePaneParams.self)
        let rowsRequest = try #require(await channel.request(PhoneMethod.rows))
        let seenRequest = try #require(await channel.request(PhoneMethod.seen))
        #expect(try seenRequest.decodeParams(PhonePaneParams.self) == PhonePaneParams(pane: "p1"))
        try channel.respond(to: seenRequest, PhonePaneParams(pane: "p1"))
        try channel.respond(
            to: rowsRequest, PhoneRowsResult(sections: [.init(name: "demo", isPlugin: false, rows: [])]))
        #expect(try await seen.pane == "p1")
        #expect(try await rows.sections.map(\.name) == ["demo"])
    }

    @Test func theMacsErrorIsThrownAsItCame() async throws {
        let channel = PipeChannel()
        let client = PhoneClient(channel: channel)
        let answer = Task {
            try await client.call(
                PhoneMethod.answer, PhoneAnswerParams(pane: "p1", prompt: "x", answer: .init(allow: true)),
                as: PhonePaneParams.self)
        }
        try channel.fail(try #require(await channel.request(PhoneMethod.answer)), code: "prompt_gone")
        await #expect(throws: ControlError(code: "prompt_gone", message: "prompt_gone message")) {
            try await answer.value
        }
    }

    @Test func eventsRightBehindTheResponseAreKept() async throws {
        let channel = PipeChannel()
        let client = PhoneClient(channel: channel)
        async let started = client.stream(PhoneMethod.subscribe, as: PhoneInbox.self)
        let request = try #require(await channel.request(PhoneMethod.subscribe))
        try channel.respond(to: request, PhoneInbox(rows: []))
        try channel.emit(
            PhoneEvent.inbox, subscription: request.id, PhoneInbox(rows: [PhoneRow(path: "/a", name: "a")]))
        try channel.emit(
            PhoneEvent.inbox, subscription: request.id, PhoneInbox(rows: [PhoneRow(path: "/b", name: "b")]))
        let stream = try await started
        #expect(stream.result == PhoneInbox(rows: []))
        #expect(stream.subscription == request.id)
        var names: [String] = []
        for await event in stream.events {
            names += try event.data.decode(PhoneInbox.self).rows.map(\.name)
            if names.count == 2 { break }
        }
        #expect(names == ["a", "b"])
    }

    @Test func eventsGoOnlyToTheirSubscription() async throws {
        let channel = PipeChannel()
        let client = PhoneClient(channel: channel)
        async let first = client.stream(PhoneMethod.screen, PhonePaneParams(pane: "p1"), as: PhoneScreen.self)
        let firstRequest = try #require(await channel.request(PhoneMethod.screen))
        try channel.respond(to: firstRequest, PhoneScreen(pane: "p1", columns: 80, rows: 24, lines: ["one"]))
        let one = try await first
        async let second = client.stream(PhoneMethod.screen, PhonePaneParams(pane: "p2"), as: PhoneScreen.self)
        _ = await eventually { channel.requests.filter { $0.method == PhoneMethod.screen }.count == 2 }
        let secondRequest = try #require(channel.requests.last)
        try channel.respond(to: secondRequest, PhoneScreen(pane: "p2", columns: 80, rows: 24, lines: ["two"]))
        let two = try await second
        try channel.emit(
            PhoneEvent.screen, subscription: "nobody", PhoneScreen(pane: "p9", columns: 1, rows: 1, lines: []))
        try channel.emit(
            PhoneEvent.screen, subscription: two.subscription,
            PhoneScreen(pane: "p2", columns: 80, rows: 24, lines: ["2"]))
        try channel.emit(
            PhoneEvent.screen, subscription: one.subscription,
            PhoneScreen(pane: "p1", columns: 80, rows: 24, lines: ["1"]))
        var oneEvents = one.events.makeAsyncIterator()
        var twoEvents = two.events.makeAsyncIterator()
        #expect(try await oneEvents.next()?.data.decode(PhoneScreen.self).lines == ["1"])
        #expect(try await twoEvents.next()?.data.decode(PhoneScreen.self).lines == ["2"])
    }

    @Test func aStreamTheMacRefusesThrowsAndKeepsNothing() async throws {
        let channel = PipeChannel()
        let client = PhoneClient(channel: channel)
        let started = Task {
            try await client.stream(
                PhoneMethod.transcript, PhoneTranscriptParams(pane: "p1", follow: true), as: PhoneTranscriptResult.self)
        }
        try channel.fail(try #require(await channel.request(PhoneMethod.transcript)), code: "no_transcript")
        await #expect(throws: ControlError.self) { try await started.value }
        #expect(await client.streamCount == 0)
    }

    @Test func unsubscribingTellsTheMacAndEndsTheStream() async throws {
        let channel = PipeChannel()
        let client = PhoneClient(channel: channel)
        async let started = client.stream(PhoneMethod.screen, PhonePaneParams(pane: "p1"), as: PhoneScreen.self)
        let request = try #require(await channel.request(PhoneMethod.screen))
        try channel.respond(to: request, PhoneScreen(pane: "p1", columns: 80, rows: 24, lines: []))
        let stream = try await started
        let ended = Task {
            for await _ in stream.events {}
        }
        let unsubscribing = Task { try await client.unsubscribe(stream.subscription) }
        let unsubscribe = try #require(await channel.request(PhoneMethod.unsubscribe))
        #expect(
            try unsubscribe.decodeParams(PhoneUnsubscribeParams.self)
                == PhoneUnsubscribeParams(subscription: stream.subscription))
        await ended.value
        #expect(await client.streamCount == 0)
        try channel.respond(to: unsubscribe, PhoneUnsubscribeParams(subscription: stream.subscription))
        try await unsubscribing.value
    }

    @Test func aDropFailsWaitingCallsAndEndsEveryStream() async throws {
        let channel = PipeChannel()
        let client = PhoneClient(channel: channel)
        async let started = client.stream(PhoneMethod.subscribe, as: PhoneInbox.self)
        let request = try #require(await channel.request(PhoneMethod.subscribe))
        try channel.respond(to: request, PhoneInbox())
        let stream = try await started
        let rows = Task { try await client.call(PhoneMethod.rows, as: PhoneRowsResult.self) }
        _ = await channel.request(PhoneMethod.rows)
        channel.drop(PhoneTransportError.unreachable("gone"))
        await #expect(throws: PhoneTransportError.closed) { try await rows.value }
        for await _ in stream.events {}
        await client.closed()
        await #expect(throws: PhoneTransportError.closed) {
            try await client.call(PhoneMethod.rows, as: PhoneRowsResult.self)
        }
    }

    @Test func closingEndsWaitingCallsAtOnce() async throws {
        let channel = PipeChannel()
        let client = PhoneClient(channel: channel)
        let rows = Task { try await client.call(PhoneMethod.rows, as: PhoneRowsResult.self) }
        _ = await channel.request(PhoneMethod.rows)
        await client.close()
        await #expect(throws: PhoneTransportError.closed) { try await rows.value }
        #expect(await client.isClosed)
    }

    @Test func aCancelledCallStopsWaiting() async throws {
        let channel = PipeChannel()
        let client = PhoneClient(channel: channel)
        let call = Task { try await client.call(PhoneMethod.rows, as: PhoneRowsResult.self) }
        let request = try #require(await channel.request(PhoneMethod.rows))
        call.cancel()
        await #expect(throws: CancellationError.self) { try await call.value }
        try channel.respond(to: request, PhoneRowsResult(sections: []))
        #expect(await client.waitingCount == 0)
    }

    @Test func aLineTheClientCannotReadIsSkipped() async throws {
        let channel = PipeChannel()
        let client = PhoneClient(channel: channel)
        async let rows = client.call(PhoneMethod.rows, as: PhoneRowsResult.self)
        let request = try #require(await channel.request(PhoneMethod.rows))
        channel.writeRaw("{not json")
        channel.writeRaw(#"{"v": 1, "event": "phone.inbox"}"#)
        try channel.respond(to: request, PhoneRowsResult(sections: []))
        #expect(try await rows == PhoneRowsResult(sections: []))
    }

    @Test func aStreamCancelledBeforeItsResponseIsUnsubscribedOnceItStarts() async throws {
        let channel = PipeChannel()
        let client = PhoneClient(channel: channel)
        let started = Task {
            try await client.stream(PhoneMethod.screen, PhonePaneParams(pane: "p1"), as: PhoneScreen.self)
        }
        let request = try #require(await channel.request(PhoneMethod.screen))
        started.cancel()
        await #expect(throws: CancellationError.self) { try await started.value }
        try channel.respond(to: request, PhoneScreen(pane: "p1", columns: 80, rows: 24, lines: []))
        let unsubscribe = try #require(await channel.request(PhoneMethod.unsubscribe))
        #expect(try unsubscribe.decodeParams(PhoneUnsubscribeParams.self).subscription == request.id)
    }

    @Test func aCancelledStreamTheMacRefusedNeedsNoUnsubscribe() async throws {
        let channel = PipeChannel()
        let client = PhoneClient(channel: channel)
        let started = Task {
            try await client.stream(PhoneMethod.screen, PhonePaneParams(pane: "p1"), as: PhoneScreen.self)
        }
        let request = try #require(await channel.request(PhoneMethod.screen))
        started.cancel()
        _ = try? await started.value
        try channel.fail(request, code: "pane_not_found")
        let rows = Task { try await client.call(PhoneMethod.rows, as: PhoneRowsResult.self) }
        try channel.respond(to: try #require(await channel.request(PhoneMethod.rows)), PhoneRowsResult(sections: []))
        _ = try await rows.value
        #expect(!channel.requests.contains { $0.method == PhoneMethod.unsubscribe })
    }
}
