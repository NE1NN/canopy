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

    /// `canopy ticket show`: the header, the messages as plain text, the problems, the draft, the notes, and the fix
    /// rows, leaving out sections with nothing in them.
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

        if !detail.problems.isEmpty {
            lines += ["", "Problems"]
            for problem in detail.problems {
                lines.append(
                    "  "
                        + ([problem.status, problem.title] + [problem.category].compactMap { $0 }).joined(
                            separator: " · "))
                lines += problem.bullets.map { "    - " + $0 }
            }
        }
        if let draft = detail.draft {
            var title = ["Draft", draft.status].filter { !$0.isEmpty }
            if let generatedAt = draft.generatedAt {
                title.append(TicketAge.ago(Date(milliseconds: generatedAt), now: now))
            }
            lines += ["", title.joined(separator: " · ")]
            lines += draft.text.components(separatedBy: "\n").map { "  " + $0 }
            if let error = draft.error { lines.append("  Failed: \(error)") }
        }
        if !detail.notes.isEmpty {
            lines += ["", "Notes"]
            for note in detail.notes {
                lines.append(
                    "  \(note.authorEmail ?? "Someone") · \(TicketAge.ago(Date(milliseconds: note.createdAt), now: now))"
                )
                lines += note.text.components(separatedBy: "\n").map { "    " + $0 }
            }
        }
        if !result.fixRows.isEmpty {
            lines += ["", "Fix rows"]
            for row in result.fixRows {
                var parts = [
                    row.displayName, URL(fileURLWithPath: row.repoPath).lastPathComponent,
                    tilde(row.path, homeFolder: homeFolder),
                ]
                if let pr = row.pullRequest { parts.append("PR #\(pr.number)") }
                lines.append("  " + parts.joined(separator: " · "))
            }
        }
        return clean(lines.joined(separator: "\n"))
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
