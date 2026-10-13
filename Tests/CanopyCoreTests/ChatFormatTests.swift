import CanopyTestSupport
import Foundation
import Testing

@testable import CanopyCore

struct ChatFormatTests {
    @Test func durations() {
        #expect(ChatFormat.duration(0.4) == "0s")
        #expect(ChatFormat.duration(41) == "41s")
        #expect(ChatFormat.duration(72) == "1m 12s")
        #expect(ChatFormat.duration(220) == "3m 40s")
        #expect(ChatFormat.duration(3780) == "1h 3m")
    }

    @Test func clocks() {
        #expect(ChatFormat.clock(8) == "0:08")
        #expect(ChatFormat.clock(750) == "12:30")
        #expect(ChatFormat.clock(3725) == "1:02:05")
    }

    @Test func tokens() {
        #expect(ChatFormat.tokens(850) == "850")
        #expect(ChatFormat.tokens(2300) == "2.3k")
        #expect(ChatFormat.tokens(2000) == "2k")
        #expect(ChatFormat.tokens(41_900) == "41k")
        #expect(ChatFormat.tokens(1_250_000) == "1.2M")
    }

    @Test func context() {
        #expect(ChatFormat.context(used: 140_000, window: 1_000_000) == "14% of context")
        #expect(ChatFormat.context(used: 5, window: 0) == "")
    }
}
