import Foundation
import Testing

@testable import CanopyBoxKit

struct TailnetAddressesTests {
    @Test func onlyTailnetAddressesOnTailscale0Count() {
        let interfaces: [(name: String, address: String)] = [
            ("tailscale0", "100.101.102.103"), ("tailscale0", "fd7a:115c:a1e0::1"), ("tailscale0", "fe80::1"),
            ("eth0", "100.64.0.9"), ("eth0", "10.0.0.5"), ("tailscale0", "100.128.0.1"), ("tailscale0", "100.63.0.1"),
        ]
        #expect(TailnetAddresses.tailnet(interfaces) == ["100.101.102.103", "fd7a:115c:a1e0::1"])
    }

    @Test func anOverrideWinsForTests() {
        #expect(TailnetAddresses.current(override: "127.0.0.1,::1") == ["127.0.0.1", "::1"])
    }

    @Test func theNameComesFromTailscaleStatus() {
        let json = Data(#"{"Self": {"DNSName": "hindie-box.tail1234.ts.net.", "HostName": "hindie-box"}}"#.utf8)
        #expect(TailnetAddresses.name(fromStatus: json) == "hindie-box.tail1234.ts.net")
        #expect(TailnetAddresses.name(fromStatus: Data("{}".utf8)) == nil)
    }

    @Test func thisMachinesInterfacesCanBeRead() {
        #expect(TailnetAddresses.interfaces().contains { $0.address == "127.0.0.1" })
    }
}
