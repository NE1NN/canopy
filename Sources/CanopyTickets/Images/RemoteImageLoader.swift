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

/// Streams the body in the pieces it arrives in, so a missing or false Content-Length never lets more than `limit`
/// bytes into memory.
public struct URLSessionImageDownloader: ImageDownloading {
    private let session: URLSession

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration)
    }

    public func download(_ url: URL, limit: Int) async throws -> Data {
        let task = session.dataTask(with: url)
        let download = LimitedDownload(limit: limit)
        task.delegate = download
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                download.start(task, continuation)
            }
        } onCancel: {
            task.cancel()
        }
    }
}

/// One download's body, which stops the task once it would pass `limit`.
private final class LimitedDownload: NSObject, URLSessionDataDelegate, Sendable {
    private struct State {
        var body = Data()
        var failure: ImageDownloadError?
        var continuation: CheckedContinuation<Data, any Error>?
    }

    private let limit: Int
    private let state = Mutex(State())

    init(limit: Int) {
        self.limit = limit
    }

    func start(_ task: URLSessionDataTask, _ continuation: CheckedContinuation<Data, any Error>) {
        state.withLock { $0.continuation = continuation }
        task.resume()
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse
    ) async -> URLSession.ResponseDisposition {
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return refuse(.failed) }
        guard response.expectedContentLength <= Int64(limit) else { return refuse(.tooBig) }
        state.withLock { $0.body.reserveCapacity(Int(max(0, response.expectedContentLength))) }
        return .allow
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let isOver = state.withLock { current in
            guard current.failure == nil else { return false }
            guard current.body.count + data.count <= limit else {
                current.failure = .tooBig
                current.body = Data()
                return true
            }
            current.body.append(data)
            return false
        }
        if isOver { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (continuation, result) = state.withLock {
            current -> (CheckedContinuation<Data, any Error>?, Result<Data, any Error>) in
            defer { current.continuation = nil }
            if let failure = current.failure { return (current.continuation, .failure(failure)) }
            if let error { return (current.continuation, .failure(error)) }
            return (current.continuation, .success(current.body))
        }
        continuation?.resume(with: result)
    }

    private func refuse(_ failure: ImageDownloadError) -> URLSession.ResponseDisposition {
        state.withLock { $0.failure = failure }
        return .cancel
    }
}

/// Lets a few downloads run at once, and the rest wait their turn.
private actor DownloadSlots {
    private var free: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(_ count: Int) {
        free = count
    }

    func take() async {
        guard free == 0 else {
            free -= 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func give() {
        if waiting.isEmpty { free += 1 } else { waiting.removeFirst().resume() }
    }
}

/// The images ticket panels show, loaded off the main actor, four downloads at a time. A download stops past 20 MB,
/// and a file is decoded downsampled to the box its view draws it in, so neither a large file nor a small one with
/// huge dimensions can take much memory. Loaded images stay in a cache that counts decoded bytes, gives way under
/// memory pressure and past 128 MB, and is keyed by address without its query, since Discord signs the same file's
/// link afresh from time to time. A file found too big is remembered while Canopy runs, and other failures are not.
public final class RemoteImageLoader: Sendable {
    public static let shared = RemoteImageLoader()
    public static let largestDownload = 20 * 1024 * 1024
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

    private enum Lookup {
        case known(RemoteImageOutcome)
        case loading(Task<RemoteImageOutcome, Never>)
    }

    private let downloader: any ImageDownloading
    private let limit: Int
    private let slots = DownloadSlots(4)
    private let state = Mutex(State())
    // NSCache is thread-safe.
    nonisolated(unsafe) private let images: NSCache<NSString, Entry>

    public init(downloader: any ImageDownloading = URLSessionImageDownloader(), limit: Int = largestDownload) {
        self.downloader = downloader
        self.limit = limit
        images = NSCache()
        images.totalCostLimit = 128 * 1024 * 1024
    }

    /// What is known without asking the network: the image cached for this box, or a file found too big.
    public func known(_ url: URL, fitting box: CGSize) -> RemoteImageOutcome? {
        state.withLock { known(url, fitting: box, in: $0) }
    }

    /// Loads the image, downsampled to fit `box` in pixels, once however many views ask for it at the same time.
    public func load(_ url: URL, fitting box: CGSize) async -> RemoteImageOutcome {
        let file = Self.key(url)
        let key = file + " \(Int(box.width))x\(Int(box.height))"
        let lookup = state.withLock { current -> Lookup in
            if let known = known(url, fitting: box, in: current) { return .known(known) }
            if let task = current.loading[key] { return .loading(task) }
            let task = Task.detached { [self] in
                let outcome = await fetch(url, fitting: box)
                if case .loaded(let image) = outcome {
                    images.setObject(Entry(image), forKey: key as NSString, cost: image.cost)
                }
                state.withLock { current in
                    current.loading[key] = nil
                    if case .tooBig = outcome { current.tooBig.insert(file) }
                }
                return outcome
            }
            current.loading[key] = task
            return .loading(task)
        }
        switch lookup {
        case .known(let outcome): return outcome
        case .loading(let task): return await task.value
        }
    }

    private func known(_ url: URL, fitting box: CGSize, in state: State) -> RemoteImageOutcome? {
        let file = Self.key(url)
        let key = file + " \(Int(box.width))x\(Int(box.height))"
        if let entry = images.object(forKey: key as NSString) { return .loaded(entry.image) }
        return state.tooBig.contains(file) ? .tooBig : nil
    }

    private func fetch(_ url: URL, fitting box: CGSize) async -> RemoteImageOutcome {
        await slots.take()
        let data: Data
        do {
            data = try await downloader.download(url, limit: limit)
            await slots.give()
        } catch {
            await slots.give()
            if case ImageDownloadError.tooBig = error { return .tooBig }
            return .failed
        }
        return Self.decode(data, fitting: box)
    }

    /// The image downsampled to fit `box` in pixels, never enlarged, or `.tooBig` for one with more pixels than Canopy
    /// decodes. Its size in points follows the file's resolution, as `NSImage(data:)` reads it.
    static func decode(
        _ data: Data, fitting box: CGSize = CGSize(width: 1600, height: 1600), mostPixels: Int = mostPixels
    ) -> RemoteImageOutcome {
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
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let (shownWidth, shownHeight) = (5...8).contains(orientation) ? (height, width) : (width, height)
        let fit = min(1, box.width / Double(shownWidth), box.height / Double(shownHeight))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int((Double(max(width, height)) * fit).rounded(.up))),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return .failed
        }
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
