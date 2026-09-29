import CanopyCore
import SwiftUI

/// The worktree rows made for one of a plugin's items, with their PR badges, for a plugin's panel to show. Clicking one
/// selects it.
struct LinkedRowsView: View {
    @Environment(AppModel.self) private var model
    let plugin: String
    let item: String

    var body: some View {
        let rows = model.snapshot.linkedRows(plugin: plugin, item: item)
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(title: "Linked rows", count: rows.isEmpty ? nil : rows.count) {}
            if rows.isEmpty {
                Text("`canopy row new` run in this row's terminal makes a row linked to it.")
                    .font(Style.meta)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
            }
            ForEach(rows) { row in
                LinkedRowLine(row: row)
            }
        }
    }
}

private struct LinkedRowLine: View {
    @Environment(AppModel.self) private var model
    let row: Row
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            RowMark(row: row)
                .frame(width: 16)
            Text(row.displayName)
                .font(Style.row)
                .lineLimit(1)
                .truncationMode(.middle)
            if let repo = model.snapshot.repo(path: row.repoPath) {
                Text(repo.name)
                    .font(Style.meta)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let pr = row.pullRequest {
                PullRequestNumber(pr: pr)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Style.rowHeight)
        .background(isHovering ? Style.hoverFill : .clear, in: RoundedRectangle(cornerRadius: Style.cornerRadius))
        .contentShape(Rectangle())
        .onTapGesture { model.reveal(row.path) }
        .onHover { isHovering = $0 }
        .help("Show \(row.displayName)")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.reveal(row.path) }
    }
}
