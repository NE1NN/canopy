import Testing

@testable import CanopyCore

struct RelayCLITests {
    static let relayed = ["CANOPY_HOST": "box"]

    @Test func onLocalIsThisMacEvenThroughTheRelay() {
        #expect(RowTarget.host(on: "local", environment: [:]) == nil)
        #expect(RowTarget.host(on: "local", environment: Self.relayed) == nil)
    }

    @Test func onAHostIsThatHost() {
        #expect(RowTarget.host(on: "other", environment: [:]) == "other")
        #expect(RowTarget.host(on: "other", environment: Self.relayed) == "other")
    }

    @Test func noOnThroughTheRelayIsTheRelaysHost() {
        #expect(RowTarget.host(on: nil, environment: Self.relayed) == "box")
    }

    @Test func noOnOnThisMacIsThisMac() {
        #expect(RowTarget.host(on: nil, environment: [:]) == nil)
        #expect(RowTarget.host(on: nil, environment: ["CANOPY_HOST": ""]) == nil)
    }

    @Test func onlyARunThroughTheRelayHasAHost() {
        #expect(RelayRun.host(in: Self.relayed) == "box")
        #expect(RelayRun.host(in: [:]) == nil)
        #expect(RelayRun.host(in: ["CANOPY_HOST": ""]) == nil)
    }

    @Test func hooksThroughTheRelayPointToHostAdd() {
        #expect(ClaudeHooks.keptByHostAdd(on: "box") == "Canopy's hooks on box are kept by `canopy host add`.")
    }

}
