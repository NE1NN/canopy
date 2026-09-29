import Foundation

/// A ticket's last response as a row's folder keeps it, and when it was fetched.
public struct CachedTicket: Sendable, Equatable {
    public var detail: TicketDetail
    public var data: Data
    public var fetchedAt: Date

    public init(detail: TicketDetail, data: Data, fetchedAt: Date) {
        self.detail = detail
        self.data = data
        self.fetchedAt = fetchedAt
    }
}

/// The files in a ticket row's folder: `ticket.md` for agents, and `ticket.json`, so the panel shows at once after a
/// relaunch and while ticket-manager cannot be reached.
public enum TicketFiles {
    public static let markdownName = "ticket.md"
    public static let jsonName = "ticket.json"

    /// The handover block, then a line saying Canopy rewrites the file and how to get the latest.
    public static func markdown(handover: String) -> String {
        var text = handover
        while text.hasSuffix("\n") { text.removeLast() }
        return text
            + "\n\n_Canopy rewrites this file when it fetches a newer copy of the ticket. Run `canopy ticket show --md` "
            + "for the latest._\n"
    }

    /// Writes both files from a response's bytes, each only when its contents change, so agents watching them see a
    /// change only when there is one. `ticket.json`'s modification date says when the ticket was last fetched. A folder
    /// that is not there is left alone. Returns whether either file changed.
    @discardableResult
    public static func write(detail: TicketDetail, data: Data, fetchedAt: Date, into folder: String) throws -> Bool {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder), isFolder.boolValue else {
            return false
        }
        let markdownChanged = try replace(
            folder + "/" + markdownName, with: Data(markdown(handover: detail.handover).utf8))
        let json = folder + "/" + jsonName
        let jsonChanged = try replace(json, with: data)
        try FileManager.default.setAttributes([.modificationDate: fetchedAt], ofItemAtPath: json)
        return markdownChanged || jsonChanged
    }

    /// The last response saved in `folder`, or nil when there is none or it does not decode.
    public static func read(from folder: String) -> CachedTicket? {
        let path = folder + "/" + jsonName
        guard let data = FileManager.default.contents(atPath: path),
            let detail = try? JSONDecoder().decode(TicketDetail.self, from: data),
            let fetchedAt = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        else { return nil }
        return CachedTicket(detail: detail, data: data, fetchedAt: fetchedAt)
    }

    private static func replace(_ path: String, with data: Data) throws -> Bool {
        guard FileManager.default.contents(atPath: path) != data else { return false }
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        return true
    }
}
