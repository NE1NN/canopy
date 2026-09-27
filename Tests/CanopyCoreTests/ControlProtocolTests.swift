import Foundation
import Testing

@testable import CanopyCore

struct JSONValueTests {
    @Test func roundTripsTypedValues() throws {
        let params = RowNewParams(target: TargetHint(repo: "web"), branch: "fix/a", select: true, run: "claude")
        let decoded = try JSONValue.from(params).decode(RowNewParams.self)
        #expect(decoded.branch == "fix/a")
        #expect(decoded.select)
        #expect(decoded.run == "claude")
    }

    @Test func paramsDefaultWhatIsLeftOut() throws {
        let new = try JSONValue.object(["branch": .string("fix/x")]).decode(RowNewParams.self)
        #expect(new.target == TargetHint())
        #expect(!new.select)
        #expect(new.setup)
        #expect(new.run == nil)

        let remove = try JSONValue.object([:]).decode(RowRemoveParams.self)
        #expect(!remove.force && !remove.deleteBranch)
        #expect(try JSONValue.object([:]).decode(RowListParams.self).all == false)
        #expect(try JSONValue.object([:]).decode(RowRefParams.self).target == TargetHint())
        #expect(try JSONValue.object([:]).decode(PRShowParams.self).refresh == false)
        #expect(throws: DecodingError.self) { try JSONValue.object([:]).decode(RowNewParams.self) }
    }

    @Test func aRowWithNoPullRequestSaysNull() throws {
        let shown = PRShowResult(repo: "demo", branch: "feat/x", path: "/x", pr: nil)

        #expect(String(decoding: try JSONEncoder().encode(shown), as: UTF8.self).contains(#""pr":null"#))
    }

    @Test func keepsIntegersIntegral() throws {
        let data = try JSONEncoder().encode(JSONValue.number(42))
        #expect(String(decoding: data, as: UTF8.self) == "42")
    }

    @Test func encodedLinesHaveExactlyOneNewline() throws {
        let line = try ControlCodec.encodeLine(ControlRequest(method: "x", params: .string("a\nb"), id: "1"))
        #expect(line.filter { $0 == 0x0A }.count == 1)
        #expect(line.last == 0x0A)
    }

    @Test func writesWaitLongerThanReads() {
        #expect(ControlMethod.replyTimeout(for: ControlMethod.rowNew) == nil)
        #expect(ControlMethod.replyTimeout(for: ControlMethod.rowRemove) == nil)
        #expect(ControlMethod.replyTimeout(for: ControlMethod.repoAdd).map { $0 >= 600 } == true)
        #expect(ControlMethod.replyTimeout(for: ControlMethod.status).map { $0 <= 60 } == true)
        #expect(ControlMethod.replyTimeout(for: ControlMethod.rowList).map { $0 <= 60 } == true)
        // A refresh can wait behind a lookup already asking GitHub, and each gets 30 seconds.
        #expect(ControlMethod.replyTimeout(for: ControlMethod.prShow).map { $0 >= 60 } == true)
    }

    @Test func clientFailuresMapToStableCodes() {
        #expect(ControlError(ControlClientError.socketPathTooLong("/x")).code == "socket_path_too_long")
        #expect(ControlError(ControlClientError.connectFailed(errno: ENOENT)).code == "app_unavailable")
        #expect(ControlError(ControlClientError.connectFailed(errno: EACCES)).code == "connect_failed")
        #expect(ControlError(ControlClientError.connectionClosed).code == "connection_closed")
        #expect(ControlError(ControlClientError.writeFailed(errno: EPIPE)).code == "connection_closed")
        #expect(ControlError(ControlClientError.timedOut).code == "timeout")
        #expect(ControlError(ControlClientError.timedOut).message.contains("may still finish"))
    }
}
