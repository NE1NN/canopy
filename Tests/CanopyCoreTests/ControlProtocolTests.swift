import Foundation
import Testing

@testable import CanopyCore

struct JSONValueTests {
    @Test func roundTripsTypedValues() throws {
        let params = RowNewParams(target: TargetHint(repo: "web"), branch: "fix/a", base: nil, select: true)
        let decoded = try JSONValue.from(params).decode(RowNewParams.self)
        #expect(decoded.branch == "fix/a")
        #expect(decoded.select)
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
        #expect(ControlMethod.replyTimeout(for: ControlMethod.rowNew) >= 600)
        #expect(ControlMethod.replyTimeout(for: ControlMethod.rowRemove) >= 600)
        #expect(ControlMethod.replyTimeout(for: ControlMethod.status) <= 60)
        #expect(ControlMethod.replyTimeout(for: ControlMethod.rowList) <= 60)
    }
}
