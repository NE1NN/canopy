import CanopyTestSupport
import Foundation
import Testing

@testable import CanopyCore

struct TailscaleAddressTests {
    @Test func keepsOnlyTailscaleAddressesOnTunnels() {
        let interfaces = [
            NetworkInterfaceAddress(interface: "en0", address: "192.168.1.20"),
            NetworkInterfaceAddress(interface: "en0", address: "100.64.0.9"),
            NetworkInterfaceAddress(interface: "utun4", address: "100.101.5.9"),
            NetworkInterfaceAddress(interface: "utun4", address: "fd7a:115c:a1e0::5a01:509"),
            NetworkInterfaceAddress(interface: "utun4", address: "fe80::1"),
            NetworkInterfaceAddress(interface: "utun2", address: "100.128.0.1"),
            NetworkInterfaceAddress(interface: "utun2", address: "100.63.255.255"),
            NetworkInterfaceAddress(interface: "utun3", address: "fd7a:115c:a1e1::1"),
            NetworkInterfaceAddress(interface: "lo0", address: "127.0.0.1"),
        ]
        #expect(TailscaleAddresses.select(interfaces) == ["100.101.5.9", "fd7a:115c:a1e0::5a01:509"])
    }

    @Test func readsThisMacsInterfaces() {
        #expect(NetworkInterfaceAddress.current().contains { $0.interface == "lo0" && $0.address == "127.0.0.1" })
    }
}

struct PhoneListenAddressTests {
    @Test func aReleaseBuildListensOnTailscale() {
        #expect(
            PhoneListenAddress.resolve(environment: [:], allowsOverride: false)
                == .tailscale(port: PhonePort.standard, ignored: nil))
    }

    @Test func aReleaseBuildIgnoresTheOverride() {
        let resolved = PhoneListenAddress.resolve(
            environment: ["CANOPY_PHONE_LISTEN": "0.0.0.0:6974"], allowsOverride: false)
        #expect(resolved == .tailscale(port: PhonePort.standard, ignored: "0.0.0.0:6974"))
    }

    @Test func aDevBuildListensWhereTheEnvironmentSays() {
        let resolved = PhoneListenAddress.resolve(
            environment: ["CANOPY_PHONE_LISTEN": "127.0.0.1:7123"], allowsOverride: true)
        #expect(resolved == .address("127.0.0.1", port: 7123))
        let v6 = PhoneListenAddress.resolve(environment: ["CANOPY_PHONE_LISTEN": "[::1]:7123"], allowsOverride: true)
        #expect(v6 == .address("::1", port: 7123))
    }

    @Test func aDevBuildWithoutAnOverrideStaysClosed() {
        #expect(PhoneListenAddress.resolve(environment: [:], allowsOverride: true) == .closed(malformed: nil))
        let empty = PhoneListenAddress.resolve(environment: ["CANOPY_PHONE_LISTEN": ""], allowsOverride: true)
        #expect(empty == .closed(malformed: nil))
    }

    @Test(arguments: ["127.0.0.1", "127.0.0.1:", ":7123", "127.0.0.1:99999", "localhost:7123"])
    func aMalformedOverrideKeepsADevBuildClosed(_ text: String) {
        #expect(
            PhoneListenAddress.resolve(environment: ["CANOPY_PHONE_LISTEN": text], allowsOverride: true)
                == .closed(malformed: text))
    }
}
