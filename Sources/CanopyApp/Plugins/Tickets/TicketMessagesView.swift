import CanopyCore
import CanopyTickets
import SwiftUI

/// The conversation, then the problems, the draft, the notes, and the fix rows, in one scroll. It opens at the end of
/// the conversation, follows new messages only while that end is in view, and otherwise keeps its place.
struct TicketBody: View {
    let row: PluginRow
    let detail: TicketDetail
    @State private var position = ScrollPosition(idType: String.self)
    @State private var isEndInView = true

    private static let end = "messages-end"

    var body: some View {
        let groups = MessageGroup.groups(detail.messages)
        let threads = detail.messages.compactMap(\.thread)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel(title: "Messages", count: detail.messages.count) {}
                    .id("messages")
                ForEach(groups) { group in
                    MessageGroupView(group: group, ticket: detail.ticket, threads: threads)
                        .id(group.id)
                }
                Color.clear
                    .frame(height: 1)
                    .id(Self.end)
                TicketSections(row: row, detail: detail)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
            .scrollTargetLayout()
        }
        .scrollPosition($position)
        .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.01) { visible in
            isEndInView = visible.contains(Self.end)
        }
        .onAppear { position.scrollTo(id: Self.end, anchor: .bottom) }
        .onChange(of: detail.messages.last?.id) {
            guard isEndInView else { return }
            withAnimation(.easeOut(duration: 0.2)) { position.scrollTo(id: Self.end, anchor: .bottom) }
        }
    }
}

/// One author's messages under one header, as Discord groups them.
private struct MessageGroupView: View {
    let group: MessageGroup
    let ticket: TicketSummary
    let threads: [MessageThread]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AuthorAvatar(author: group.author)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: group.author.shownName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(group.author.role == .staff ? Color.accentColor : .primary)
                        .lineLimit(1)
                    if group.author.isBot {
                        Text("BOT")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .frame(height: 14)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 3))
                    }
                    Text(verbatim: MessageTime.text(group.posted, now: .now))
                        .font(Style.meta)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if let label = group.threadLabel {
                    Label(label, systemImage: "arrow.turn.down.right")
                        .font(Style.meta)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }
                ForEach(group.messages) { message in
                    MessageView(
                        message: message, names: DiscordNames(message: message, ticket: ticket, threads: threads))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 7)
    }
}

private struct MessageView: View {
    let message: TicketMessage
    let names: DiscordNames

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !message.text.isEmpty {
                DiscordTextView(blocks: DiscordMarkdown.parse(message.text, names: names))
            }
            ForEach(Array(message.attachments.enumerated()), id: \.offset) { _, attachment in
                AttachmentView(attachment: attachment, message: message)
            }
        }
        .help(message.posted.formatted(date: .complete, time: .standard))
    }
}

/// The author's picture, or their initials on a color of their own while there is none.
private struct AuthorAvatar: View {
    let author: MessageAuthor

    var body: some View {
        let size = 28.0
        Group {
            if let text = author.avatarUrl, let url = URL(string: text) {
                RemoteImageView(url: url, maxHeight: size, rounding: size / 2, placeholderHeight: size) { initials }
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                initials
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var initials: some View {
        Text(verbatim: String(author.shownName.prefix(1)).uppercased())
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(Circle().fill(TicketLook.ownerColor(author.username).color))
    }
}
