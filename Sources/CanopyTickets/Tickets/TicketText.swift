import CanopyCore
import Foundation

/// Tickets as `canopy ticket` prints them.
public enum TicketText {
    /// `canopy ticket list`: the row title, "waiting 7h" or "2h ago", the owner's initials, and the row's folder, lined
    /// up without trailing spaces.
    public static func listLines(_ entries: [TicketListEntry], now: Date, homeFolder: String) -> [String] {
        let rows = entries.map { entry in
            let ticket = entry.ticket
            let age =
                ticket.waiting
                ? "waiting " + TicketAge.span(from: ticket.lastActivity, to: now)
                : ShortAge.text(ticket.lastActivity, now: now)
            return [
                TicketName.rowTitle(for: ticket.name), age, ticket.owner?.initials ?? "",
                entry.row.map { tilde($0.path, homeFolder: homeFolder) } ?? "",
            ]
        }
        guard let columns = rows.first?.count else { return [] }
        let widths = (0..<columns).map { column in rows.map { $0[column].count }.max() ?? 0 }
        return rows.map { cells in
            var line = ""
            for (column, cell) in cells.enumerated() {
                line +=
                    column == columns - 1
                    ? cell : cell.padding(toLength: widths[column] + 2, withPad: " ", startingAt: 0)
            }
            while line.hasSuffix(" ") { line.removeLast() }
            return clean(line)
        }
    }

    /// `canopy ticket show`: the header, then the conversation as plain text.
    public static func show(_ result: TicketShowResult, now: Date, homeFolder: String) -> String {
        let detail = result.ticket
        let ticket = detail.ticket
        var header = [ticket.name, ticket.status.text, ticket.customer]
        if let owner = ticket.owner { header.append("owner \(owner.initials)") }
        if ticket.waiting { header.append("waiting " + TicketAge.span(from: ticket.lastActivity, to: now)) }
        var lines = [header.joined(separator: " · "), "Discord: \(ticket.discordUrl)"]
        if let row = result.row { lines.append("Row: \(tilde(row.path, homeFolder: homeFolder))") }

        lines += ["", "Messages"]
        let threads = detail.messages.compactMap(\.thread)
        for group in MessageGroup.groups(detail.messages) {
            var title = [group.author.shownName + (group.author.isBot ? " (bot)" : "")]
            if let label = group.threadLabel { title.append(label) }
            title.append(MessageTime.text(group.posted, now: now))
            lines.append("  " + title.joined(separator: " · "))
            for message in group.messages {
                let names = DiscordNames(message: message, ticket: ticket, threads: threads)
                let text = DiscordMarkdown.plain(message.text, names: names)
                if !text.isEmpty {
                    lines += text.components(separatedBy: "\n").map { "    " + $0 }
                }
                for attachment in message.attachments {
                    lines.append("    \(attachment.filename) (\(attachment.sizeText)) \(attachment.url)")
                }
            }
        }

        return clean(lines.joined(separator: "\n"))
    }

    /// `canopy ticket show --md`: `ticket.md` as Canopy writes it from this copy, starting with the note about
    /// customers' messages, without the final newline the terminal's print adds back.
    /// `canopy ticket repo`'s line: where ticket agents read the code, or why they cannot.
    public static func repo(_ result: TicketRepoResult) -> String {
        guard let repo = result.repo else {
            return "Tickets has no repo, so ticket agents are told Canopy does not know where the code is. "
                + "Set one with `canopy ticket repo <repo>`."
        }
        guard let path = result.path else {
            let registered =
                result.registered.isEmpty
                ? ", and none are registered." : ". Registered repos: \(result.registered.joined(separator: ", "))."
            return "Tickets names \(repo), but Canopy has no repo of that name\(registered)"
        }
        if result.missing { return "Tickets names \(repo), but its folder \(path) is missing." }
        guard let branch = result.defaultBranch else {
            return "Ticket agents read the code in \(repo) at \(path). Canopy cannot tell its default branch, because "
                + "origin/HEAD is not set: run `git -C \(NewRowAction.quoted(path)) remote set-head origin --auto`."
        }
        return "Ticket agents read the code in \(repo) at \(path), on \(branch)."
    }

    public static func markdown(_ detail: TicketDetail) -> String {
        String(TicketFiles.markdown(handover: detail.handover).dropLast())
    }

    /// Text with control characters taken out, but for newlines and tabs, so customer text can never send a terminal
    /// escape sequence.
    public static func clean(_ text: String) -> String {
        String(
            String.UnicodeScalarView(
                text.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || $0.properties.generalCategory != .control }))
    }

    static func tilde(_ path: String, homeFolder: String) -> String {
        path.hasPrefix(homeFolder + "/") ? "~" + path.dropFirst(homeFolder.count) : path
    }
}
