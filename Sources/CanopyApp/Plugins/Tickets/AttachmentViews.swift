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

/// Images the panels load. Loaded ones stay in a cache that gives way under memory pressure and past 128 MB, keyed by
/// address without its query, since Discord signs the same file's link afresh from time to time. A failure is not
/// kept, so the next view asks again. Downloads stop at 20 MB.
@MainActor
final class RemoteImages {
    enum Phase {
        case loaded(NSImage)
        case failed
    }

    static let shared = RemoteImages()
    static let largestDownload = 20 * 1024 * 1024

    private let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 128 * 1024 * 1024
        return cache
    }()
    private var loading: [String: Task<(NSImage, Int)?, Never>] = [:]
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()

    func cached(_ url: URL) -> Phase? {
        images.object(forKey: Self.key(url) as NSString).map(Phase.loaded)
    }

    func load(_ url: URL) async -> Phase {
        let key = Self.key(url)
        if let image = images.object(forKey: key as NSString) { return .loaded(image) }
        let task =
            loading[key]
            ?? Task<(NSImage, Int)?, Never> { [session] in
                guard let (bytes, response) = try? await session.bytes(from: url),
                    (response as? HTTPURLResponse)?.statusCode == 200,
                    response.expectedContentLength <= Self.largestDownload
                else { return nil }
                var data = Data()
                do {
                    for try await byte in bytes {
                        data.append(byte)
                        if data.count > Self.largestDownload { return nil }
                    }
                } catch {
                    return nil
                }
                return NSImage(data: data).map { ($0, data.count) }
            }
        loading[key] = task
        let loaded = await task.value
        loading[key] = nil
        guard let (image, size) = loaded else { return .failed }
        images.setObject(image, forKey: key as NSString, cost: size)
        return .loaded(image)
    }

    private static func key(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        return components?.string ?? url.absoluteString
    }
}
