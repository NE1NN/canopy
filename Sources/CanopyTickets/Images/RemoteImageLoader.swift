import CoreGraphics
import Foundation
import ImageIO
import Synchronization

/// An image ready to draw, and the size in points its file asks for.
public struct RemoteImage: Sendable {
    public let cgImage: CGImage
    public let size: CGSize

    /// The bytes it holds decoded, which is what the cache counts.
    var cost: Int { cgImage.bytesPerRow * cgImage.height }
}

public enum RemoteImageOutcome: Sendable {
    case loaded(RemoteImage)
    /// Over the download cap, or with more pixels than Canopy decodes.
    case tooBig
    case failed
}

public enum ImageDownloadError: Error, Sendable {
    case tooBig
    case failed
}

public protocol ImageDownloading: Sendable {
    /// The body of a 200 answer. Throws `.tooBig` as soon as more than `limit` bytes are announced or have arrived.
    func download(_ url: URL, limit: Int) async throws -> Data
}

/// Streams the body, so a missing or false Content-Length never lets more than `limit` bytes into memory.
public struct URLSessionImageDownloader: ImageDownloading {
    private let session: URLSession

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration)
    }

    public func download(_ url: URL, limit: Int) async throws -> Data {
        let (bytes, response) = try await session.bytes(from: url)
        defer { bytes.task.cancel() }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ImageDownloadError.failed }
        guard response.expectedContentLength <= Int64(limit) else { throw ImageDownloadError.tooBig }
        var body: [UInt8] = []
        body.reserveCapacity(Int(max(0, response.expectedContentLength)))
        for try await byte in bytes {
            guard body.count < limit else { throw ImageDownloadError.tooBig }
            body.append(byte)
        }
        return Data(body)
    }
}

/// The images ticket panels show, loaded off the main actor. A download stops past 20 MB, and a file is decoded
/// downsampled to at most 1600 pixels on its longest side, so neither a large file nor a small one with huge
/// dimensions can take much memory. Loaded images stay in a cache that counts decoded bytes, gives way under memory
/// pressure and past 128 MB, and is keyed by address without its query, since Discord signs the same file's link
/// afresh from time to time. A file found too big is remembered while Canopy runs, and other failures are not.
public final class RemoteImageLoader: Sendable {
    public static let shared = RemoteImageLoader()
    public static let largestDownload = 20 * 1024 * 1024
    static let largestPixelSide = 1600
    /// About an 8K screen's worth. Files with more pixels are never decoded.
    static let mostPixels = 50_000_000

    private final class Entry {
        let image: RemoteImage

        init(_ image: RemoteImage) {
            self.image = image
        }
    }

    private struct State {
        var tooBig: Set<String> = []
        var loading: [String: Task<RemoteImageOutcome, Never>] = [:]
    }

    private let downloader: any ImageDownloading
    private let limit: Int
    private let state = Mutex(State())
    // NSCache is thread-safe.
    nonisolated(unsafe) private let images: NSCache<NSString, Entry>

    public init(downloader: any ImageDownloading = URLSessionImageDownloader(), limit: Int = largestDownload) {
        self.downloader = downloader
        self.limit = limit
        images = NSCache()
        images.totalCostLimit = 128 * 1024 * 1024
    }

    /// What is known without asking the network: a cached image, or a file found too big.
    public func known(_ url: URL) -> RemoteImageOutcome? {
        let key = Self.key(url)
        if let entry = images.object(forKey: key as NSString) { return .loaded(entry.image) }
        return state.withLock { $0.tooBig.contains(key) } ? .tooBig : nil
    }

    /// Loads the image once however many views ask for it at the same time.
    public func load(_ url: URL) async -> RemoteImageOutcome {
        if let known = known(url) { return known }
        let key = Self.key(url)
        let task = state.withLock { current in
            if let task = current.loading[key] { return task }
            let task = Task.detached { [self] in
                let outcome = await fetch(url)
                if case .loaded(let image) = outcome {
                    images.setObject(Entry(image), forKey: key as NSString, cost: image.cost)
                }
                state.withLock { current in
                    current.loading[key] = nil
                    if case .tooBig = outcome { current.tooBig.insert(key) }
                }
                return outcome
            }
            current.loading[key] = task
            return task
        }
        return await task.value
    }

    private func fetch(_ url: URL) async -> RemoteImageOutcome {
        do {
            return Self.decode(try await downloader.download(url, limit: limit))
        } catch ImageDownloadError.tooBig {
            return .tooBig
        } catch {
            return .failed
        }
    }

    /// The image downsampled to `largestSide` pixels on its longest side, or `.tooBig` for one with more pixels than
    /// Canopy decodes. Its size in points follows the file's resolution, as `NSImage(data:)` reads it.
    static func decode(_ data: Data, largestSide: Int = largestPixelSide, mostPixels: Int = mostPixels)
        -> RemoteImageOutcome
    {
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0
        else { return .failed }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels <= mostPixels else { return .tooBig }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), largestSide),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return .failed
        }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let (shownWidth, shownHeight) = (5...8).contains(orientation) ? (height, width) : (width, height)
        let dpi = properties[kCGImagePropertyDPIWidth] as? Double ?? 72
        let scale = dpi > 0 ? 72 / dpi : 1
        return .loaded(
            RemoteImage(
                cgImage: image, size: CGSize(width: Double(shownWidth) * scale, height: Double(shownHeight) * scale)))
    }

    static func key(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        return components?.string ?? url.absoluteString
    }
}
