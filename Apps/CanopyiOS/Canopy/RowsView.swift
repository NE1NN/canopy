import CanopyPhone
import CanopyWire
import SwiftUI

/// Every row, by repo then plugin, with each repo's main row as a card above its others.
struct RowsView: View {
    @Environment(PhoneApp.self) private var app
    @State private var path: [PaneLink] = []

    private var model: RowsModel { app.rows }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                } header: {
                    HostLabel()
                }
                ForEach(model.sections) { section in
                    if section.isPlugin {
                        Section {
                            ForEach(section.rows) { RowLine(row: $0) }
                        } header: {
                            GroupLabel(title: section.name)
                        }
                    } else {
                        Section {
                            if let main = section.main { MainCard(row: main) }
                        } header: {
                            RepoLabel(name: section.name)
                        }
                        if !section.others.isEmpty {
                            Section {
                                ForEach(section.others) { RowLine(row: $0) }
                            }
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

/// The Mac's name and whether it is connected, above its repos.
private struct HostLabel: View {
    @Environment(PhoneApp.self) private var app

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "laptopcomputer")
            Text(app.connection.macName)
            Spacer()
            Circle().fill(color).frame(width: 6, height: 6)
            Text(status).textCase(nil)
        }
        .font(.footnote)
        .textCase(.uppercase)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("host")
    }

    private var color: Color {
        switch app.connection.status {
        case .connected: Theme.green
        case .connecting: Theme.yellow
        case .unreachable: Color.secondary
        }
    }

    private var status: String {
        switch app.connection.status {
        case .connected: "connected"
        case .connecting: "connecting"
        case .unreachable:
            app.inbox.asOf.map { "as of \($0.formatted(date: .omitted, time: .shortened))" } ?? "out of reach"
        }
    }
}

private struct RepoLabel: View {
    var name: String

    var body: some View {
        HStack(spacing: 7) {
            RepoTile(name: name, dot: nil, size: 18)
            Text(name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .textCase(nil)
        .padding(.leading, -4)
    }
}

/// A repo's own checkout, larger than its other rows.
private struct MainCard: View {
    var row: PhoneRow

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.name)
                    .font(.title3.weight(.semibold))
                    .accessibilityIdentifier("main-\(row.repo ?? row.name)")
                Text(line)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            AgentDotView(dot: row.dot)
        }
        .padding(.vertical, 4)
        .opens(row.lead?.pane)
    }

    private var line: String {
        guard let lead = row.lead else { return "No agent running" }
        return lead.lastLine ?? lead.state.phrase.capitalizedFirst
    }
}

private struct RowLine: View {
    var row: PhoneRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            AgentDotView(dot: row.dot)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    RowName(row: row, label: nil, muted: row.lead == nil, weight: .medium)
                        .accessibilityIdentifier("row-\(row.name)")
                    Spacer(minLength: 8)
                    if let pr = row.pr {
                        PRChip(pr: pr)
                    }
                }
                if let line = row.lead?.lastLine {
                    Text(line)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
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
