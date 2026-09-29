import AppKit
import CanopyTickets
import SwiftUI

/// An image inline, a file as a link with its name and size, or an attachment whose link expired as its name, which
/// opens the message in Discord.
struct AttachmentView: View {
    let attachment: MessageAttachment
    let message: TicketMessage
    @Environment(\.openURL) private var openURL

    var body: some View {
        let url = URL(string: attachment.url)
        if attachment.isExpired(now: .now) || url == nil {
            expired
        } else if let url, attachment.kind == .image {
            RemoteImageView(url: url, maxHeight: 240, rounding: 6, placeholderHeight: 120) { expired }
                .onTapGesture { openURL(url) }
                .help("\(attachment.filename), \(attachment.sizeText). Opens in the browser.")
        } else if let url {
            AttachmentChip(systemImage: "paperclip", name: attachment.filename, detail: attachment.sizeText) {
                openURL(url)
            }
            .help("Open \(attachment.filename)")
        }
    }

    private var expired: some View {
        AttachmentChip(systemImage: "clock.badge.xmark", name: attachment.filename, detail: "expired", isDimmed: true) {
            if let text = message.discordUrl, let url = URL(string: text) { openURL(url) }
        }
        .help("Discord's link to \(attachment.filename) expired. Opens the message in Discord.")
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

/// An image from the network, fit to the width and at most `maxHeight` tall, kept in a cache while Canopy runs. The
/// fallback shows when it cannot be loaded.
struct RemoteImageView<Fallback: View>: View {
    let url: URL
    let maxHeight: Double
    let rounding: Double
    let placeholderHeight: Double
    @ViewBuilder var fallback: Fallback
    @State private var phase: RemoteImages.Phase?

    var body: some View {
        Group {
            switch phase ?? RemoteImages.shared.cached(url) {
            case .loaded(let image):
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(
                        maxWidth: image.size.width, maxHeight: min(maxHeight, image.size.height), alignment: .leading
                    )
                    .clipShape(RoundedRectangle(cornerRadius: rounding))
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .failed:
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
            phase = await RemoteImages.shared.load(url)
        }
    }
}

/// Images the panels load, cached by address while Canopy runs.
@MainActor
final class RemoteImages {
    enum Phase {
        case loaded(NSImage)
        case failed
    }

    static let shared = RemoteImages()

    private var images: [URL: Phase] = [:]
    private var loading: [URL: Task<Phase, Never>] = [:]
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()

    func cached(_ url: URL) -> Phase? {
        images[url]
    }

    func load(_ url: URL) async -> Phase {
        if let phase = images[url] { return phase }
        if let task = loading[url] { return await task.value }
        let session = session
        let task = Task<Phase, Never> {
            guard let (data, response) = try? await session.data(from: url),
                (response as? HTTPURLResponse)?.statusCode == 200, let image = NSImage(data: data)
            else { return .failed }
            return .loaded(image)
        }
        loading[url] = task
        let phase = await task.value
        loading[url] = nil
        images[url] = phase
        return phase
    }
}
