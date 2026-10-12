import CanopyPhone
import CanopyWire
import SwiftUI

/// Every row by repo and plugin, with dots and PR numbers, for the rows the inbox leaves out.
struct RowsView: View {
    @Environment(PhoneApp.self) private var app
    @State private var path: [PaneLink] = []

    private var model: RowsModel { app.rows }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                let sections = model.sections
                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    Section {
                        if !section.isPlugin {
                            RepoHeader(section: section)
                        }
                        ForEach(section.rows) { row in
                            RowLine(row: row, indented: !section.isPlugin)
                        }
                    } header: {
                        if section.isPlugin {
                            GroupLabel(title: section.name)
                        } else if index == sections.firstIndex(where: { !$0.isPlugin }) {
                            GroupLabel(title: "Repos")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            .overlay {
                if model.result == nil {
                    if let problem = model.problem {
                        ContentUnavailableView(
                            problem.title, systemImage: "exclamationmark.triangle", description: Text(problem.detail))
                    } else if app.connection.isUnreachable {
                        ContentUnavailableView(
                            "Can't reach \(app.connection.macName)", systemImage: "wifi.slash",
                            description: Text(verbatim: PhoneProblemText.checkTailscale))
                    } else {
                        ProgressView()
                    }
                }
            }
            .opacity(app.connection.isUnreachable && model.result != nil ? 0.55 : 1)
            .refreshable { await model.refresh() }
            .navigationTitle("Rows")
            .backButtonTitle("Rows")
            .navigationDestination(for: PaneLink.self) { link in
                ConversationView(app: app, pane: link.pane)
            }
        }
        .environment(\.openPane, OpenPaneAction { path.append(PaneLink(pane: $0)) })
    }
}

private struct RepoHeader: View {
    var section: PhoneRowsResult.Section

    var body: some View {
        HStack(spacing: 10) {
            RepoTile(name: section.name, dot: nil, size: 18)
            Text(section.name).font(.body.weight(.semibold))
            Spacer()
            Text(verbatim: "\(section.rows.count)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private struct RowLine: View {
    var row: PhoneRow
    var indented: Bool

    var body: some View {
        HStack(spacing: 10) {
            AgentDotView(dot: row.dot)
            RowName(row: row, label: nil, muted: row.lead == nil, weight: .medium)
                .accessibilityIdentifier("row-\(row.name)")
            Spacer(minLength: 8)
            if let pr = row.pr {
                PRChip(pr: pr)
            }
        }
        .padding(.leading, indented ? 22 : 0)
        .opens(row.lead?.pane)
    }
}

struct PRChip: View {
    var pr: PhonePR

    var body: some View {
        Text(verbatim: "#\(pr.number)")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .foregroundStyle(color)
            .background(pr.state == .draft ? Theme.fill : color.opacity(0.16), in: .rect(cornerRadius: 5))
            .accessibilityLabel("Pull request \(pr.number), \(pr.state.rawValue)")
    }

    private var color: Color {
        switch pr.state {
        case .open: Theme.green
        case .draft: .secondary
        case .merged: Theme.purple
        case .closed: Theme.red
        }
    }
}
