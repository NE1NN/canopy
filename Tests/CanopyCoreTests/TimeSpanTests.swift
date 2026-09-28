import Testing

@testable import CanopyCore

struct TimeSpanTests {
    @Test func spansReadLikeTheLogsOnes() {
        #expect(TimeSpan.seconds("90s") == 90)
        #expect(TimeSpan.seconds("30m") == 1800)
        #expect(TimeSpan.seconds("2h") == 7200)
        #expect(TimeSpan.seconds("1d") == 86_400)
        #expect(TimeSpan.seconds("1w") == 604_800)
        #expect(TimeSpan.seconds("45") == 45)
        #expect(TimeSpan.seconds("0s") == 0)
        #expect(TimeSpan.seconds(" 5M ") == 300)
        for text in ["", "5x", "-1m", "1.5h", "m", "1234567s"] {
            #expect(TimeSpan.seconds(text) == nil, "\(text)")
        }
    }
}
