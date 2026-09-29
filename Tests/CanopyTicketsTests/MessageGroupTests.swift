import Foundation
import Testing

@testable import CanopyTickets

struct MessageGroupTests {
    let detail = try! APIFixture.decode(TicketDetail.self, "ticket-detail")

    func message(_ id: String, _ author: String, at seconds: Int64, thread: MessageThread? = nil) -> TicketMessage {
        TicketMessage(
            id: id, discordUrl: nil,
            author: MessageAuthor(username: author, displayName: nil, avatarUrl: nil, role: .customer, isBot: false),
            text: id, mentions: [], attachments: [], postedAt: seconds * 1000, thread: thread)
    }

    @Test func oneAuthorWithinSevenMinutesSharesAHeader() {
        let groups = MessageGroup.groups([
            message("1", "sam", at: 0), message("2", "sam", at: 400), message("3", "sam", at: 830),
            message("4", "ann", at: 840), message("5", "sam", at: 850),
        ])
        #expect(groups.map { $0.messages.map(\.id) } == [["1", "2"], ["3"], ["4"], ["5"]])
        #expect(groups.map(\.id) == ["1", "3", "4", "5"])
        #expect(groups[0].posted == Date(timeIntervalSince1970: 0))
    }

    @Test func aThreadStartsAGroupAndSaysSo() {
        let groups = MessageGroup.groups(detail.messages)
        #expect(groups.map(\.threadLabel) == [nil, nil, nil, "in a thread", "in thread Shadowban check", nil])
        let thread = MessageThread(id: "t", name: nil)
        let split = MessageGroup.groups([message("1", "sam", at: 0), message("2", "sam", at: 10, thread: thread)])
        #expect(split.count == 2)
    }

    @Test func messageTimes() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_GB")
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let text = { (offset: TimeInterval) in
            MessageTime.text(now.addingTimeInterval(offset), now: now, calendar: calendar, locale: locale)
        }
        #expect(text(-60) == "Today at 14:12")
        #expect(text(-86_400) == "Yesterday at 14:13")
        #expect(text(-864_000) == "11 Sep 2026 at 14:13")
    }

    @Test func attachmentsKnowTheirKindSizeAndExpiry() {
        let image = detail.messages[1].attachments[0]
        let csv = detail.messages[5].attachments[0]
        #expect(image.kind == .image && csv.kind == .file)
        #expect(image.sizeText == "47 KB" && csv.sizeText == "1 KB")
        #expect(MessageAttachment(filename: "a", url: "u", size: 3_355_443, contentType: nil).sizeText == "3.2 MB")
        #expect(MessageAttachment(filename: "a", url: "u", size: 900, contentType: nil).sizeText == "900 B")
        #expect(MessageAttachment(filename: "shot.JPG", url: "u", size: 1, contentType: nil).kind == .image)
        let now = Date(timeIntervalSince1970: 0x6700_0000)
        var signed = image
        signed.url = "https://cdn.discordapp.com/a/b/c.png?ex=66ff0000&is=66fe0000&hm=abc"
        #expect(signed.isExpired(now: now))
        signed.url = "https://cdn.discordapp.com/a/b/c.png?ex=67100000&is=66fe0000&hm=abc"
        #expect(!signed.isExpired(now: now))
        #expect(!image.isExpired(now: now))
    }
}
