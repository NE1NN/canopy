import AppKit
import CanopyCore
import CanopyTickets
import SwiftUI

/// Everything after the conversation: problems, the draft, notes, and fix rows.
struct TicketSections: View {
    let row: PluginRow
    let detail: TicketDetail

    var body: some View {
        if !detail.problems.isEmpty {
            SectionLabel(title: "Problems", count: detail.problems.count) {}
                .padding(.top, 10)
                .id("problems")
            VStack(alignment: .leading, spacing: 10) {
                ForEach(detail.problems) { problem in
                    ProblemView(problem: problem)
                }
            }
        }
        if let draft = detail.draft {
            DraftView(draft: draft)
                .padding(.top, 10)
                .id("draft")
        }
        if !detail.notes.isEmpty {
            SectionLabel(title: "Notes", count: detail.notes.count) {}
                .padding(.top, 10)
                .id("notes")
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(detail.notes.enumerated()), id: \.offset) { _, note in
                    NoteView(note: note)
                }
            }
        }
        LinkedRowsView(
            plugin: row.plugin, item: row.item, title: "Fix rows",
            emptyHint: "Run `canopy row new` in this row's terminal to make a fix row linked to this ticket."
        )
        .padding(.horizontal, -8)
        .padding(.top, 10)
        .id("fixes")
    }
}

private struct ProblemView: View {
    let problem: TicketProblem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: problem.isOpen ? "open" : problem.status)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(problem.isOpen ? Color(nsColor: .systemOrange) : Color(nsColor: .systemGreen))
                    .padding(.horizontal, 5)
                    .frame(height: 15)
                    .background(
                        (problem.isOpen ? Color(nsColor: .systemOrange) : Color(nsColor: .systemGreen)).opacity(0.14),
                        in: RoundedRectangle(cornerRadius: Style.tagRadius))
                Text(verbatim: problem.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(problem.isOpen ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let category = problem.category {
                    Text(verbatim: category)
                        .font(Style.meta)
                        .foregroundStyle(.tertiary)
                }
            }
            ForEach(Array(problem.bullets.enumerated()), id: \.offset) { _, bullet in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: "•")
                    Text(verbatim: bullet)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(Style.body)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            }
        }
        .textSelection(.enabled)
    }
}

/// ticket-manager's suggested reply, with a button that copies it.
private struct DraftView: View {
    let draft: TicketDraft
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title: "Draft") {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(draft.text, forType: .string)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(Style.meta.weight(.medium))
                }
                .buttonStyle(.borderless)
                .help("Copy the draft")
                .task(id: copied) {
                    guard copied else { return }
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            }
            Text(verbatim: draft.text)
                .font(.system(size: 13))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Style.badgeFill, in: RoundedRectangle(cornerRadius: 8))
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(verbatim: details(now: context.date))
                    .font(Style.meta)
                    .foregroundStyle(.tertiary)
            }
            if let error = draft.error {
                Text(verbatim: error)
                    .font(Style.meta)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func details(now: Date) -> String {
        var parts = [draft.status]
        if !draft.sourcesUsed.isEmpty { parts.append("from " + draft.sourcesUsed.joined(separator: ", ")) }
        if let generatedAt = draft.generatedAt {
            parts.append(TicketAge.ago(Date(timeIntervalSince1970: Double(generatedAt) / 1000), now: now))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

private struct NoteView: View {
    let note: TicketNote

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: note.text)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(
                    verbatim:
                        "\(note.authorEmail ?? "Someone") · \(TicketAge.ago(Date(timeIntervalSince1970: Double(note.createdAt) / 1000), now: context.date))"
                )
                .font(Style.meta)
                .foregroundStyle(.tertiary)
            }
        }
    }
}
