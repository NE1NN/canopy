import CanopyWire
import Foundation
import Observation

public enum TerminalKey: Sendable, CaseIterable {
    case escape, tab, up, down, left, right, enter

    var sequence: String {
        switch self {
        case .escape: "\u{1b}"
        case .tab: "\t"
        case .up: "\u{1b}[A"
        case .down: "\u{1b}[B"
        case .right: "\u{1b}[C"
        case .left: "\u{1b}[D"
        case .enter: "\r"
        }
    }
}

/// The Terminal tab: the pane's screen at the Mac's width, and keys typed into it.
@MainActor @Observable
public final class TerminalModel {
    public let connection: MacConnection
    public let pane: String
    public private(set) var columns = 80
    public private(set) var scrollback: [[StyledRun]] = []
    public private(set) var screen: [[StyledRun]] = []
    public private(set) var hasLoaded = false
    public private(set) var problem: PhoneProblem?
    /// The key bar's ctrl, held for the next key.
    public var ctrl = false

    private var watching: Task<Void, Never>?
    private var subscription: (client: PhoneClient, id: String)?
    /// Keys typed while an earlier send is on its way go out together, after it.
    private var unsent = ""
    private var isSending = false

    public init(connection: MacConnection, pane: String) {
        self.connection = connection
        self.pane = pane
    }

    public var lines: [[StyledRun]] { scrollback + screen }
    public var lineCount: Int { scrollback.count + screen.count }

    public func start() {
        guard watching == nil else { return }
        watching = Task { await self.run() }
    }

    public func stop() {
        watching?.cancel()
        watching = nil
        if let subscription {
            self.subscription = nil
            Task { try? await subscription.client.unsubscribe(subscription.id) }
        }
    }

    private func run() async {
        var generation = 0
        while !Task.isCancelled {
            do {
                let connected = try await connection.client(after: generation)
                generation = connected.generation
                let stream = try await connected.client.stream(
                    PhoneMethod.screen, PhonePaneParams(pane: pane), as: PhoneScreen.self)
                guard !Task.isCancelled else {
                    try? await connected.client.unsubscribe(stream.subscription)
                    return
                }
                subscription = (connected.client, stream.subscription)
                show(stream.result, scrollback: true)
                for await event in stream.events {
                    if let screen = try? event.data.decode(PhoneScreen.self) { show(screen, scrollback: false) }
                }
                subscription = nil
            } catch let error as ControlError {
                problem = connection.problem(error)
                return
            } catch {
                if Task.isCancelled { return }
            }
        }
    }

    private func show(_ screen: PhoneScreen, scrollback withScrollback: Bool) {
        columns = screen.columns
        if withScrollback { scrollback = (screen.scrollback ?? []).map(StyledText.runs) }
        self.screen = screen.lines.map(StyledText.runs)
        hasLoaded = true
    }

    /// What the keyboard typed. With ctrl held, a letter goes as its control character.
    public func type(_ text: String) {
        var text = text.replacingOccurrences(of: "\n", with: "\r")
        if ctrl {
            ctrl = false
            if text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first,
                let control = Self.control(scalar)
            {
                text = String(control)
            }
        }
        send(text)
    }

    public func backspace() {
        send("\u{7f}")
    }

    public func press(_ key: TerminalKey) {
        ctrl = false
        send(key.sequence)
    }

    private static func control(_ scalar: Unicode.Scalar) -> Unicode.Scalar? {
        let value = scalar.properties.lowercaseMapping.unicodeScalars.first?.value ?? scalar.value
        switch value {
        case 0x61...0x7A: return Unicode.Scalar(value - 0x60)
        case 0x40, 0x5B...0x5F: return Unicode.Scalar(value - 0x40)
        case 0x20: return Unicode.Scalar(0)
        default: return nil
        }
    }

    private func send(_ text: String) {
        guard !text.isEmpty else { return }
        unsent += text
        guard !isSending else { return }
        isSending = true
        Task {
            defer { isSending = false }
            while !unsent.isEmpty {
                let text = unsent
                unsent = ""
                do {
                    _ = try await connection.liveClient().call(
                        PhoneMethod.keys, PhoneKeysParams(pane: pane, text: text), as: PhonePaneParams.self)
                    problem = nil
                } catch {
                    problem = connection.problem(error)
                    unsent = ""
                }
            }
        }
    }
}
