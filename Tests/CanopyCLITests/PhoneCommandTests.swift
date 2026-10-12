import CoreImage
import Foundation
import Testing

@testable import CanopyCLI
@testable import CanopyCore

struct QRCodeTests {
    @Test func encodesTheLinkSoAScannerReadsItBack() throws {
        let link = "canopy-phone://pair?host=studio.tail1234.ts.net&port=6974&code=K7QX-M2PD&addr=100.101.5.9"
        let matrix = try #require(QRCode.matrix(for: link))
        #expect(matrix.count == matrix.first?.count)
        #expect(try Self.scan(matrix) == link)
    }

    @Test func drawsTwoRowsOfModulesPerLineInsideAQuietZone() {
        let matrix = [[true, false], [false, true], [true, true]]
        let lines = QRCode.text(matrix, quietZone: 1, colored: false).split(
            separator: "\n", omittingEmptySubsequences: false)
        // Five rows with the quiet zone make three lines, two rows each. Dark modules are drawn.
        #expect(lines == [" ▄  ", " ▄█ ", "    "])
    }

    @Test func colorsItBlackOnWhiteForAnyTheme() {
        let text = QRCode.text([[true]], quietZone: 0, colored: true)
        #expect(text == "\u{1b}[30;107m▀\u{1b}[0m")
    }

    /// Reads a QR code back with Core Image, as a stand-in for the phone's camera.
    static func scan(_ matrix: [[Bool]]) throws -> String? {
        let scale = 8
        let quiet = 4
        let size = (matrix.count + 2 * quiet) * scale
        var pixels = [UInt8](repeating: 255, count: size * size)
        for (y, row) in matrix.enumerated() {
            for (x, dark) in row.enumerated() where dark {
                for dy in 0..<scale {
                    for dx in 0..<scale {
                        pixels[((y + quiet) * scale + dy) * size + (x + quiet) * scale + dx] = 0
                    }
                }
            }
        }
        let image = CIImage(
            bitmapData: Data(pixels), bytesPerRow: size, size: CGSize(width: size, height: size), format: .L8,
            colorSpace: CGColorSpaceCreateDeviceGray())
        let detector = try #require(
            CIDetector(
                ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        return (detector.features(in: image).first as? CIQRCodeFeature)?.messageString
    }
}

struct PhoneCommandTextTests {
    static let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func listsPhonesWithWhenTheyLastConnected() {
        var connected = PhoneInfo(
            PairedPhone(
                id: "1", name: "Hindie's iPhone", tokenHash: "", pushToken: nil, pairedAt: Self.now - 86400 * 3,
                lastConnected: Self.now - 120),
            connected: true)
        connected.notifications = false
        let never = PhoneInfo(
            PairedPhone(
                id: "2", name: "Old", tokenHash: "", pushToken: nil, pairedAt: Self.now - 60, lastConnected: nil),
            connected: false)
        #expect(
            PhoneCommand.table([connected, never], now: Self.now)
                == """
                NAME             PAIRED  LAST SEEN  CONNECTED
                Hindie's iPhone  3d ago  2m ago     yes
                Old              1m ago  never      no
                """)
    }

    @Test func statusSaysWhereItListens() {
        let status = PhonesStatusResult(
            listening: true, endpoints: [PhoneEndpoint(address: "100.101.5.9", port: 6974)],
            host: "studio.tail1234.ts.net", problem: nil, phones: [], notifications: PhonesStatusResult.noPushKey)
        #expect(
            PhoneCommand.statusText(status)
                == """
                Listening for phones on 100.101.5.9:6974 (studio.tail1234.ts.net).
                No phones are paired. Run canopy phone pair to pair one.
                Notifications: Off: no push key on this Mac.
                """)
    }

    @Test func statusSaysWhyItIsClosed() {
        let status = PhonesStatusResult(
            listening: false, endpoints: [], host: nil, problem: "Tailscale is not running on this Mac.",
            phones: [
                PhoneInfo(
                    PairedPhone(id: "1", name: "a", tokenHash: "", pairedAt: Self.now, lastConnected: nil),
                    connected: false)
            ], notifications: PhonesStatusResult.noPushKey)
        #expect(
            PhoneCommand.statusText(status)
                == """
                Not listening for phones. Tailscale is not running on this Mac.
                1 phone is paired, none connected.
                Notifications: Off: no push key on this Mac.
                """)
    }

    @Test func bracketsAnIPv6Endpoint() {
        #expect(
            PhoneCommand.endpointText(PhoneEndpoint(address: "fd7a:115c:a1e0::1", port: 6974))
                == "[fd7a:115c:a1e0::1]:6974")
    }
}
