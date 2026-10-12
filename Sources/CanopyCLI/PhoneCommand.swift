import ArgumentParser
import CanopyCore
import Foundation

struct PhoneCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "phone",
        abstract: "Pair the Canopy iPhone app with this Mac.",
        discussion: """
            The phone reaches the Mac over Tailscale, which both must run, signed in to the same tailnet. Canopy \
            listens for phones only on this Mac's Tailscale addresses, and only paired phones get in.
            """,
        subcommands: [Pair.self, List.self, Remove.self, Status.self]
    )

    struct Pair: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show a QR code that pairs a phone.",
            discussion: "The code works once and expires after five minutes. The command waits until a phone uses it."
        )

        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(PhonesMethod.pair, JSONValue.null)
            let pairing = try result.decode(PhonesPairResult.self)
            if output.json {
                try client.print(result) { "" }
                return
            }
            let colored = isatty(STDOUT_FILENO) == 1
            if let matrix = QRCode.matrix(for: pairing.link) {
                print(QRCode.text(matrix, colored: colored))
            }
            let expires = Date(timeIntervalSince1970: pairing.expires).formatted(date: .omitted, time: .shortened)
            print(
                """

                Scan this with the Canopy app on your iPhone.
                The code \(pairing.code) works once, until \(expires).
                \(pairing.link)

                Waiting for the phone...
                """)
            fflush(stdout)
            let waited = client.call(PhonesMethod.paired, PhonesPairedParams(code: pairing.code))
            guard let phone = try waited.decode(PhonesPairedResult.self).phone else {
                client.fail(
                    ControlError(
                        code: "pairing_expired",
                        message: "The code expired before a phone used it. Run canopy phone pair again."))
            }
            print("Paired \(phone.name).")
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List paired phones.")

        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(PhonesMethod.list, JSONValue.null)
            try client.print(result) {
                let phones = try result.decode([PhoneInfo].self)
                return phones.isEmpty ? "No phones are paired." : PhoneCommand.table(phones)
            }
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Forget a phone and close its connections.",
            discussion: "The phone must be paired again before it can reach Canopy.")

        @Argument(help: "The phone's name, as canopy phone list shows it.")
        var name: String
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(PhonesMethod.remove, PhonesRemoveParams(name: name), launchIfNeeded: false)
            try client.print(result) { "Removed \(name)." }
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show whether Canopy listens for phones, and which are paired.")

        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(PhonesMethod.status, JSONValue.null)
            try client.print(result) { PhoneCommand.statusText(try result.decode(PhonesStatusResult.self)) }
        }
    }

    static func table(_ phones: [PhoneInfo], now: Date = .now) -> String {
        Table.render(
            ["NAME", "PAIRED", "LAST SEEN", "CONNECTED"],
            phones.map { phone in
                [
                    phone.name, ShortAge.text(Date(timeIntervalSince1970: phone.pairedAt), now: now),
                    phone.lastConnected.map { ShortAge.text(Date(timeIntervalSince1970: $0), now: now) } ?? "never",
                    phone.connected ? "yes" : "no",
                ]
            })
    }

    static func statusText(_ status: PhonesStatusResult) -> String {
        let listening =
            status.listening
            ? "Listening for phones on \(status.endpoints.map(endpointText).joined(separator: ", "))"
                + (status.host.map { " (\($0))" } ?? "") + "." + (status.problem.map { " \($0)" } ?? "")
            : "Not listening for phones. \(status.problem ?? "")"
        let count = status.phones.count
        let connected = status.phones.filter(\.connected).count
        let phones =
            switch count {
            case 0: "No phones are paired. Run canopy phone pair to pair one."
            case 1: "1 phone is paired, \(connected == 0 ? "none" : "\(connected)") connected."
            default: "\(count) phones are paired, \(connected == 0 ? "none" : "\(connected)") connected."
            }
        return [listening, phones, "Notifications: \(status.notifications)"].joined(separator: "\n")
    }

    static func endpointText(_ endpoint: PhoneEndpoint) -> String {
        endpoint.address.contains(":")
            ? "[\(endpoint.address)]:\(endpoint.port)" : "\(endpoint.address):\(endpoint.port)"
    }
}
