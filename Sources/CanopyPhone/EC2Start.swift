import CanopyWire
import Foundation

/// Posts a signed request, so tests can stand in for AWS.
public protocol HTTPPosting: Sendable {
    func post(_ url: URL, headers: [String: String], body: Data) async throws -> (status: Int, body: Data)
}

public struct URLSessionPoster: HTTPPosting {
    public init() {}

    public func post(_ url: URL, headers: [String: String], body: Data) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = body
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

/// `ec2:StartInstances` for one instance, and what EC2 answers.
public enum EC2Start {
    public enum Answer: Equatable, Sendable {
        /// The instance is starting or already runs.
        case starting
        /// It is still stopping, and can be started once it has.
        case stillStopping
        /// AWS refused the key.
        case refused(String)
        /// Anything else EC2 said, or nothing that reads as an answer.
        case failed(String)
    }

    /// The region's endpoint.
    public static func endpoint(region: String) -> URL {
        URL(string: "https://ec2.\(region).amazonaws.com/")!
    }

    /// The request's headers and body, signed with the wake key.
    public static func request(_ wake: PhoneWake, endpoint: URL, date: Date) -> (headers: [String: String], body: Data)
    {
        let body = Data("Action=StartInstances&InstanceId.1=\(wake.instanceID)&Version=2016-11-15".utf8)
        let signer = SigV4(
            accessKeyID: wake.accessKeyID, secretAccessKey: wake.secretAccessKey, region: wake.region, service: "ec2")
        let headers = signer.sign(
            method: "POST", url: endpoint,
            headers: ["Content-Type": "application/x-www-form-urlencoded; charset=utf-8"], body: body, date: date)
        return (headers, body)
    }

    static let refusals: Set<String> = [
        "AuthFailure", "UnauthorizedOperation", "InvalidClientTokenId", "SignatureDoesNotMatch",
    ]

    public static func answer(status: Int, body: Data) -> Answer {
        let text = String(decoding: body, as: UTF8.self)
        if (200..<300).contains(status) {
            let state = element("name", in: element("currentState", in: text) ?? "") ?? ""
            return ["pending", "running"].contains(state) ? .starting : .failed("The instance is \(state).")
        }
        let code = element("Code", in: text) ?? "HTTP \(status)"
        let message = element("Message", in: text) ?? code
        if code == "IncorrectInstanceState" { return .stillStopping }
        if refusals.contains(code) || status == 401 || status == 403 { return .refused(message) }
        return .failed(message)
    }

    /// The text inside the first `<name>…</name>`.
    private static func element(_ name: String, in text: String) -> String? {
        guard let start = text.range(of: "<\(name)>"),
            let end = text.range(of: "</\(name)>", range: start.upperBound..<text.endIndex)
        else { return nil }
        return String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
