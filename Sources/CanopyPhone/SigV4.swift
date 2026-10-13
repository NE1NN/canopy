import CryptoKit
import Foundation

/// Signs AWS requests with Signature Version 4, so the phone talks to AWS with no SDK.
public struct SigV4: Sendable {
    public var accessKeyID: String
    public var secretAccessKey: String
    public var region: String
    public var service: String

    public init(accessKeyID: String, secretAccessKey: String, region: String, service: String) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.region = region
        self.service = service
    }

    /// The headers to send: those given, `Host` and `X-Amz-Date` when missing, and `Authorization`.
    public func sign(
        method: String, url: URL, headers: [String: String] = [:], body: Data = Data(), date: Date
    ) -> [String: String] {
        let stamp = Self.timestamp(date)
        var headers = headers
        if !headers.keys.contains(where: { $0.lowercased() == "host" }) { headers["Host"] = url.host() ?? "" }
        if !headers.keys.contains(where: { $0.lowercased() == "x-amz-date" }) { headers["X-Amz-Date"] = stamp }
        let canonical = Dictionary(
            headers.map { ($0.key.lowercased(), Self.trimmed($0.value)) }, uniquingKeysWith: { first, _ in first })
        let names = canonical.keys.sorted()
        let signedHeaders = names.joined(separator: ";")
        let request = [
            method,
            Self.canonicalPath(url),
            Self.canonicalQuery(url),
            names.map { "\($0):\(canonical[$0] ?? "")\n" }.joined(),
            signedHeaders,
            Self.hex(SHA256.hash(data: body)),
        ].joined(separator: "\n")
        let day = String(stamp.prefix(8))
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let toSign = [
            "AWS4-HMAC-SHA256", stamp, scope, Self.hex(SHA256.hash(data: Data(request.utf8))),
        ].joined(separator: "\n")
        var key = SymmetricKey(data: Data("AWS4\(secretAccessKey)".utf8))
        for part in [day, region, service, "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
        }
        let signature = Self.hex(HMAC<SHA256>.authenticationCode(for: Data(toSign.utf8), using: key))
        headers["Authorization"] =
            "AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        return headers
    }

    /// `20150830T123600Z`, in UTC.
    static func timestamp(_ date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: date)
        return String(
            format: "%04d%02d%02dT%02d%02d%02dZ", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0,
            parts.minute ?? 0, parts.second ?? 0)
    }

    private static func trimmed(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// RFC 3986's unreserved characters stay; everything else is percent-encoded.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")

    private static func encoded(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }

    private static func canonicalPath(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        guard !path.isEmpty else { return "/" }
        return path.split(separator: "/", omittingEmptySubsequences: false).map { encoded(String($0)) }
            .joined(separator: "/")
    }

    private static func canonicalQuery(_ url: URL) -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.map { (encoded($0.name), encoded($0.value ?? "")) }.sorted { $0 < $1 }
            .map { "\($0.0)=\($0.1)" }.joined(separator: "&")
    }

    private static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
