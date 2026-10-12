import Foundation
import Testing

@testable import CanopyWire

struct ControlCodecTests {
    @Test func aMessageIsOneLine() throws {
        let request = ControlRequest(method: "phone.rows", params: .object(["text": "two\nlines"]), id: "1")
        let line = try ControlCodec.encodeLine(request)
        #expect(line.filter { $0 == 0x0A }.count == 1)
        #expect(line.last == 0x0A)
        #expect(try ControlCodec.decode(ControlRequest.self, from: line.dropLast()) == request)
    }

    @Test func agentStatesKeepTheirNames() throws {
        #expect(AgentState.allCases.map(\.rawValue) == ["none", "working", "waiting", "done", "background"])
    }
}
