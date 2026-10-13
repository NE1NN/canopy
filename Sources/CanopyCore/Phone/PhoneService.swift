import Foundation
import Network
import Synchronization

/// Canopy's side of the iPhone app on the Mac: a `PhoneServer` over the Mac's terminals, listening where
/// `PhoneListenAddress` says, and following network changes so it opens when Tailscale comes up and closes when it goes.
public final class PhoneService: Sendable {
    private let server: PhoneServer
    private let monitor = Mutex<NWPathMonitor?>(nil)

    public var registry: PhoneRegistry { server.registry }

    public init(
        home: CanopyHome, hub: PhoneHub, panes: PhonePanes, activity: ActivityLog, listen: PhoneListenAddress,
        macName: String,
        newRow: @escaping @Sendable (PhoneNewRowParams, String) async throws -> PhoneNewRowResult = { _, _ in
            throw ControlError(code: "unavailable", message: "This Canopy cannot start tasks from the phone.")
        },
        tailscaleAddresses: @escaping @Sendable () -> [String] = TailscaleAddresses.current,
        dnsName: @escaping @Sendable () async -> String? = TailscaleStatus.dnsName
    ) {
        let settings = PhoneServerSettings(
            registryFile: home.phonesFile, serverName: { macName },
            agentCommand: { PhoneAgentCommand.chosen(GlobalConfig.load(from: home.configFile).agentCommand) },
            version: CanopyVersion.current, port: listen.port,
            addresses: {
                switch listen {
                case .tailscale: tailscaleAddresses()
                case .address(let address, _): [address]
                case .closed: []
                }
            },
            tailnetName: { listen.isTailscale ? await dnsName() : nil },
            closedReason: { listen.closedReason },
            statusNote: listen.ignoredOverride.map {
                "CANOPY_PHONE_LISTEN=\($0) is ignored: release builds listen only on Tailscale."
            },
            logsCommands: { activity.logsCommands },
            record: { event in
                switch event {
                case .paired(let phone):
                    activity.record(ActivityType.phonePaired, source: .phone, data: ["phone": .string(phone)])
                case .removed(let phone):
                    activity.record(ActivityType.phoneRemoved, data: ["phone": .string(phone)])
                case .call(let data):
                    activity.record(ActivityType.phoneCall, source: .phone, data: data)
                }
            })
        server = PhoneServer(source: MacPhoneSource(hub: hub, panes: panes, makeRow: newRow), settings: settings)
    }

    /// Listens, and follows network changes so the listener opens when Tailscale comes up and closes when it goes.
    public func start() async {
        await refresh()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { await self?.refresh() }
        }
        monitor.start(queue: DispatchQueue(label: "canopy.phone-network"))
        self.monitor.withLock { $0 = monitor }
    }

    public func stop() {
        monitor.withLock {
            $0?.cancel()
            $0 = nil
        }
        server.stop()
    }

    public func refresh() async {
        await server.refresh()
    }

    // MARK: What `canopy phone` calls

    public func pair() async throws -> PhonesPairResult {
        try await server.pair()
    }

    public func waitForPairing(code: String) async -> PhoneInfo? {
        await server.waitForPairing(code: code)
    }

    public func list() async -> [PhoneInfo] {
        await server.list()
    }

    public func remove(name: String) async throws -> PhoneInfo {
        try await server.remove(name: name)
    }

    public func status() async -> PhonesStatusResult {
        await server.status()
    }
}

extension PhoneListenAddress {
    var isTailscale: Bool {
        if case .tailscale = self { true } else { false }
    }

    var ignoredOverride: String? {
        if case .tailscale(_, let ignored?) = self { ignored } else { nil }
    }

    /// Why there is no address to listen on.
    var closedReason: String {
        switch self {
        case .tailscale:
            return "Tailscale is not running on this Mac, or is signed out, so the Mac has no Tailscale address."
        case .address(let address, _):
            return "It could not listen on \(address)."
        case .closed(let malformed?):
            return "CANOPY_PHONE_LISTEN=\(malformed) is not an address and port, such as 127.0.0.1:7123."
        case .closed(nil):
            return
                "This dev build listens for phones only where CANOPY_PHONE_LISTEN says, such as 127.0.0.1:7123, so it never takes the tailnet port from the release app."
        }
    }
}

extension CanopyHome {
    /// Paired phones, by name, with hashes of their tokens.
    public var phonesFile: URL { root.appending(path: "phones.json") }
}

/// What the Tailscale app says about this Mac.
public enum TailscaleStatus {
    /// The Tailscale CLI, from the Mac App Store or standalone app, then Homebrew.
    static let executables = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
    ]

    /// This Mac's MagicDNS name, such as `studio.tail1234.ts.net`, or nil when Tailscale cannot say.
    @Sendable public static func dnsName() async -> String? {
        guard let executable = executables.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            return nil
        }
        let result = await onOwnThread {
            try? Subprocess.run(
                executable, ["status", "--json"], environment: [:], directory: nil,
                timeout: .seconds(3))
        }
        guard let result, result.status == 0 else { return nil }
        return dnsName(fromStatusJSON: result.stdout)
    }

    static func dnsName(fromStatusJSON data: Data) -> String? {
        struct Status: Decodable {
            struct Node: Decodable {
                var dnsName: String?

                enum CodingKeys: String, CodingKey {
                    case dnsName = "DNSName"
                }
            }
            var node: Node?

            enum CodingKeys: String, CodingKey {
                case node = "Self"
            }
        }
        guard let name = (try? JSONDecoder().decode(Status.self, from: data))?.node?.dnsName else { return nil }
        let trimmed = name.hasSuffix(".") ? String(name.dropLast()) : name
        return trimmed.isEmpty ? nil : trimmed
    }
}
