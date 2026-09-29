import AppKit
import CanopyTickets
import SwiftUI

/// An image inline, a file as a link with its name and size, or an attachment whose link expired as its name, which
/// opens the message in Discord. An image too big to show inline, or that cannot be loaded, shows as a file.
struct AttachmentView: View {
    let attachment: MessageAttachment
    let message: TicketMessage
    @Environment(\.openURL) private var openURL

    var body: some View {
        switch attachment.display(now: .now) {
        case .image(let url):
            RemoteImageView(url: url, maxHeight: 240, rounding: 6, placeholderHeight: 120) { file(url) }
                .onTapGesture { openURL(url) }
                .help("\(attachment.filename), \(attachment.sizeText). Opens in the browser.")
        case .file(let url):
            file(url)
        case .expired:
            AttachmentChip(
                systemImage: "clock.badge.xmark", name: attachment.filename, detail: "expired", isDimmed: true
            ) {
                if let text = message.discordUrl, let url = URL(string: text) { openURL(url) }
            }
            .help("Discord's link to \(attachment.filename) expired. Opens the message in Discord.")
        }
    }

    private func file(_ url: URL) -> some View {
        AttachmentChip(systemImage: "paperclip", name: attachment.filename, detail: attachment.sizeText) {
            openURL(url)
        }
        .help("Open \(attachment.filename)")
    }
}

private struct AttachmentChip: View {
    let systemImage: String
    let name: String
    let detail: String
    var isDimmed = false
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                Text(verbatim: name)
                    .foregroundStyle(isDimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: detail)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
            .font(Style.body)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(isHovering ? Style.hoverFill : Style.badgeFill, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// An image from the network, fit to the width and at most `maxHeight` tall. The fallback shows when it is too big or
/// cannot be loaded.
struct RemoteImageView<Fallback: View>: View {
    let url: URL
    let maxHeight: Double
    let rounding: Double
    let placeholderHeight: Double
    @ViewBuilder var fallback: Fallback
    @State private var outcome: RemoteImageOutcome?

    var body: some View {
        Group {
            switch outcome ?? RemoteImageLoader.shared.known(url) {
            case .loaded(let image):
                Image(decorative: image.cgImage, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(
                        maxWidth: image.size.width, maxHeight: min(maxHeight, image.size.height), alignment: .leading
                    )
                    .clipShape(RoundedRectangle(cornerRadius: rounding))
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .tooBig, .failed:
                fallback
            case nil:
                RoundedRectangle(cornerRadius: rounding)
                    .fill(Style.badgeFill)
                    .frame(
                        maxWidth: placeholderHeight < 100 ? placeholderHeight : 200, minHeight: placeholderHeight,
                        maxHeight: placeholderHeight
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: url) {
            outcome = await RemoteImageLoader.shared.load(url)
        }
    }
}
