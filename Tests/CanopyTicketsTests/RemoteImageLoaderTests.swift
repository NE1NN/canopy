import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers

@testable import CanopyTickets

/// Answers requests from what a test registered for the path, sending the body in 64 KB pieces.
final class StubImageProtocol: URLProtocol {
    struct Answer: Sendable {
        var status = 200
        /// The Content-Length header, which may differ from the body's size, or nil for none.
        var contentLength: Int?
        var body: Data
    }

    static let answers = Mutex<[String: Answer]>([:])

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubImageProtocol.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let answer = Self.answers.withLock({ $0[url.path] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        var headers = ["Content-Type": "image/png"]
        if let length = answer.contentLength { headers["Content-Length"] = String(length) }
        let response = HTTPURLResponse(
            url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: headers)
        client?.urlProtocol(self, didReceive: response!, cacheStoragePolicy: .notAllowed)
        var start = 0
        while start < answer.body.count {
            let end = min(start + 65_536, answer.body.count)
            client?.urlProtocol(self, didLoad: answer.body.subdata(in: start..<end))
            start = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Counts downloads, and how many ran at once, and answers each with what the test set.
actor CountingDownloader: ImageDownloading {
    var answer: Result<Data, ImageDownloadError>
    private(set) var downloads = 0
    private(set) var mostAtOnce = 0
    private var running = 0

    init(_ answer: Result<Data, ImageDownloadError>) {
        self.answer = answer
    }

    func download(_ url: URL, limit: Int) async throws -> Data {
        downloads += 1
        running += 1
        mostAtOnce = max(mostAtOnce, running)
        defer { running -= 1 }
        try await Task.sleep(for: .milliseconds(50))
        return try answer.get()
    }
}

enum TestImages {
    /// A PNG of `width` by `height` pixels at `dpi`.
    static func png(width: Int, height: Int, dpi: Double = 72) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(
            destination, context.makeImage()!,
            [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}

struct RemoteImageDecodingTests {
    @Test func aLargeImageIsDownsampledAndKeepsItsSize() throws {
        guard case .loaded(let image) = RemoteImageLoader.decode(TestImages.png(width: 4000, height: 100)) else {
            Issue.record("did not decode")
            return
        }
        #expect(image.cgImage.width == 1600)
        #expect(image.cgImage.height == 40)
        #expect(image.size == CGSize(width: 4000, height: 100))
    }

    @Test func aSmallImageStaysAsItIsAndARetinaOneIsHalfItsPixels() throws {
        guard case .loaded(let small) = RemoteImageLoader.decode(TestImages.png(width: 10, height: 12)),
            case .loaded(let retina) = RemoteImageLoader.decode(TestImages.png(width: 200, height: 100, dpi: 144))
        else {
            Issue.record("did not decode")
            return
        }
        #expect(small.cgImage.width == 10 && small.cgImage.height == 12)
        #expect(small.size == CGSize(width: 10, height: 12))
        #expect(retina.size == CGSize(width: 100, height: 50))
    }

    @Test func aTallImageIsDecodedToTheBoxItIsDrawnIn() throws {
        let phone = TestImages.png(width: 1170, height: 2532)
        guard case .loaded(let image) = RemoteImageLoader.decode(phone, fitting: CGSize(width: 1800, height: 480))
        else {
            Issue.record("did not decode")
            return
        }
        #expect(image.cgImage.height == 480)
        #expect(abs(image.cgImage.width - 222) <= 1)
        #expect(image.size == CGSize(width: 1170, height: 2532))
    }

    @Test func anImageWithMorePixelsThanTheLimitIsNeverDecoded() {
        let image = TestImages.png(width: 100, height: 100)
        guard case .tooBig = RemoteImageLoader.decode(image, mostPixels: 9_999),
            case .loaded = RemoteImageLoader.decode(image, mostPixels: 10_000)
        else {
            Issue.record("the pixel limit did not hold")
            return
        }
    }

    @Test func somethingThatIsNotAnImageFails() {
        guard case .failed = RemoteImageLoader.decode(Data("<html>".utf8)) else {
            Issue.record("HTML decoded")
            return
        }
    }
}

struct RemoteImageDownloadTests {
    let downloader = URLSessionImageDownloader(configuration: StubImageProtocol.configuration())

    func answer(_ path: String, _ answer: StubImageProtocol.Answer) -> URL {
        StubImageProtocol.answers.withLock { $0[path] = answer }
        return URL(string: "https://images.test\(path)")!
    }

    @Test func aBodyUnderTheLimitArrivesWhole() async throws {
        let body = TestImages.png(width: 30, height: 30)
        let url = answer("/whole-\(UUID())", .init(contentLength: body.count, body: body))
        #expect(try await downloader.download(url, limit: body.count) == body)
    }

    @Test func tooBigIsFoundFromTheHeaderTheStreamOrNeither() async {
        let body = Data(repeating: 7, count: 300_000)
        for (name, length) in [("declared", 300_000), ("lying", 10), ("unsaid", nil)] {
            let url = answer("/\(name)-\(UUID())", .init(contentLength: length, body: body))
            await #expect(throws: ImageDownloadError.tooBig, "\(name)") {
                try await downloader.download(url, limit: 100_000)
            }
        }
    }

    @Test func anAnswerOtherThan200Fails() async {
        let url = answer("/missing-\(UUID())", .init(status: 404, contentLength: 5, body: Data("nope.".utf8)))
        await #expect(throws: ImageDownloadError.failed) { try await downloader.download(url, limit: 100) }
    }
}

struct RemoteImageLoaderTests {
    static let box = CGSize(width: 1800, height: 480)

    @Test func fourDownloadsRunAtOnceAndTheRestWait() async {
        let downloader = CountingDownloader(.success(TestImages.png(width: 8, height: 8)))
        let loader = RemoteImageLoader(downloader: downloader)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<9 {
                group.addTask {
                    _ = await loader.load(URL(string: "https://cdn.test/\(index).png")!, fitting: Self.box)
                }
            }
        }
        #expect(await downloader.downloads == 9)
        #expect(await downloader.mostAtOnce == 4)
    }

    @Test func aFileFoundTooBigIsRememberedAndNeverDownloadedAgain() async {
        let downloader = CountingDownloader(.failure(.tooBig))
        let loader = RemoteImageLoader(downloader: downloader)
        let url = URL(string: "https://cdn.test/a/recording.gif?ex=1&hm=2")!
        guard case .tooBig = await loader.load(url, fitting: Self.box) else {
            Issue.record("not too big")
            return
        }
        let resigned = URL(string: "https://cdn.test/a/recording.gif?ex=3&hm=4")!
        guard case .tooBig? = loader.known(resigned, fitting: Self.box),
            case .tooBig = await loader.load(resigned, fitting: Self.box)
        else {
            Issue.record("not remembered")
            return
        }
        #expect(await downloader.downloads == 1)
    }

    @Test func otherFailuresAreAskedAgain() async {
        let downloader = CountingDownloader(.failure(.failed))
        let loader = RemoteImageLoader(downloader: downloader)
        let url = URL(string: "https://cdn.test/a/offline.png")!
        _ = await loader.load(url, fitting: Self.box)
        #expect(loader.known(url, fitting: Self.box) == nil)
        _ = await loader.load(url, fitting: Self.box)
        #expect(await downloader.downloads == 2)
    }

    @Test func viewsAskingAtOnceShareOneDownloadAndTheCacheKeepsIt() async {
        let downloader = CountingDownloader(.success(TestImages.png(width: 20, height: 20)))
        let loader = RemoteImageLoader(downloader: downloader)
        let url = URL(string: "https://cdn.test/a/shot.png?ex=1")!
        async let first = loader.load(url, fitting: Self.box)
        async let second = loader.load(url, fitting: Self.box)
        let outcomes = await [first, second]
        #expect(outcomes.allSatisfy { if case .loaded = $0 { true } else { false } })
        guard case .loaded? = loader.known(URL(string: "https://cdn.test/a/shot.png?ex=2")!, fitting: Self.box) else {
            Issue.record("not cached")
            return
        }
        #expect(await downloader.downloads == 1)
    }
}

struct AttachmentDisplayTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func attachment(_ name: String, size: Int64, type: String?, ex: String? = nil) -> MessageAttachment {
        let query = ex.map { "?ex=\($0)" } ?? ""
        return MessageAttachment(filename: name, url: "https://cdn.test/\(name)\(query)", size: size, contentType: type)
    }

    @Test func anImageOverTheCapIsAFileAndNeverDownloaded() {
        let cap = Int64(RemoteImageLoader.largestDownload)
        let url = URL(string: "https://cdn.test/shot.png")!
        #expect(attachment("shot.png", size: cap, type: "image/png").display(now: now) == .image(url))
        #expect(attachment("shot.png", size: cap + 1, type: "image/png").display(now: now) == .file(url))
        #expect(
            attachment("log.txt", size: 10, type: "text/plain").display(now: now)
                == .file(URL(string: "https://cdn.test/log.txt")!))
    }

    @Test func onlyALinkPastItsTimeIsExpired() {
        let past = String(Int(now.timeIntervalSince1970) - 1, radix: 16)
        let future = String(Int(now.timeIntervalSince1970) + 60, radix: 16)
        #expect(attachment("big.gif", size: 60_000_000, type: "image/gif", ex: past).display(now: now) == .expired)
        #expect(
            attachment("big.gif", size: 60_000_000, type: "image/gif", ex: future).display(now: now)
                == .file(URL(string: "https://cdn.test/big.gif?ex=\(future)")!))
        #expect(
            MessageAttachment(filename: "x", url: "", size: 1, contentType: nil).display(now: now) == .expired)
    }
}
