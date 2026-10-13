import Foundation

/// The Mac's rows and panes, as a phone server reaches them: the inbox from `PhoneHub`, and each pane through
/// `PhonePanes`.
struct MacPhoneSource: PhoneSource {
    let hub: PhoneHub
    let panes: PhonePanes

    func inbox() async -> PhoneInbox {
        await hub.inbox
    }

    func rows() async -> PhoneRowsResult {
        await hub.rows
    }

    func subscribe(
        after lastSent: PhoneInbox, replacing previous: UUID?, _ send: @escaping @Sendable (PhoneInbox) -> Void
    ) async -> UUID {
        await hub.subscribe(after: lastSent, replacing: previous, send)
    }

    func unsubscribe(_ id: UUID) async {
        await hub.unsubscribe(id)
    }

    func transcriptURL(_ pane: String) async throws -> URL {
        try await phoneErrors { try await panes.transcriptURL(pane) }
    }

    func reply(_ params: PhoneReplyParams, delivered: @escaping @Sendable () -> Void) async throws {
        try await phoneErrors { try await panes.reply(params, delivered: delivered) }
    }

    func answer(_ params: PhoneAnswerParams) async throws {
        try await phoneErrors { try await panes.answer(params) }
    }

    func keys(_ params: PhoneKeysParams) async throws {
        try await phoneErrors { try await panes.keys(params) }
    }

    func seen(_ params: PhonePaneParams) async throws {
        try await phoneErrors { try await panes.seen(params) }
    }

    func screen(_ params: PhonePaneParams, scrollback: Int?) async throws -> PhoneScreen {
        try await phoneErrors { try await panes.screen(params, scrollback: scrollback) }
    }

    /// The phone reads a `ControlError`'s code, so a workspace error crosses as one.
    private func phoneErrors<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch let error as WorkspaceError {
            throw ControlError(error)
        }
    }
}
