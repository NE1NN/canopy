import Foundation
import Testing

@testable import CanopyCore

struct ShortAgeTests {
    @Test func saysHowLongAgoInOneUnit() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let cases: [(TimeInterval, String)] = [
            (-30, "now"), (0, "now"), (59, "now"), (60, "1m ago"), (59 * 60, "59m ago"), (3600, "1h ago"),
            (23 * 3600 + 3599, "23h ago"), (86400, "1d ago"), (6 * 86400, "6d ago"), (7 * 86400, "1w ago"),
            (29 * 86400, "4w ago"), (30 * 86400, "1mo ago"), (364 * 86400, "12mo ago"), (365 * 86400, "1y ago"),
            (800 * 86400, "2y ago"),
        ]
        for (seconds, text) in cases {
            #expect(ShortAge.text(now.addingTimeInterval(-seconds), now: now) == text, "\(seconds)")
        }
    }

    @Test func readsISOTimes() {
        let now = Date(timeIntervalSince1970: 1_789_869_600)
        #expect(ShortAge.text("2026-09-20T00:00:00Z", now: now) == "2h ago")
        #expect(ShortAge.text("yesterday", now: now) == "yesterday")
    }
}
