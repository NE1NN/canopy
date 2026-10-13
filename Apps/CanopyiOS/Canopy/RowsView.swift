import CanopyPhone
import CanopyWire
import SwiftUI

/// Every row, by host in pairing order, then repo and plugin, with each repo's main row as a card above its others.
struct RowsView: View {
    @Environment(PhoneApp.self) private var app
    @State private var path: [PaneRef] = []

    private var model: RowsModel { app.rows }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(model.hosts) { host in
                    HostSections(host: host, isFirst: host.id == model.hosts.first?.id)
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            .refreshable { await model.refresh() }
            .navigationTitle("Rows")
            .backButtonTitle("Rows")
            .navigationDestination(for: PaneRef.self) { ref in
                PaneDestination(ref: ref)
            }
        }
        .environment(\.openPane, OpenPaneAction { path.append($0) })
    }
}

/// One server's rows under its name: greyed, as of when it last answered, while it is out of reach.
private struct HostSections: View {
    var host: RowsModel.Host
    var isFirst: Bool

    private var server: ServerConnection { host.server }
    private var dim: Double { server.isUnreachable ? 0.55 : 1 }

    var body: some View {
        Section {
            if host.sections.isEmpty { empty }
        } header: {
            // A host's rows sit apart from the host above them.
            HostLabel(server: server).padding(.top, isFirst ? 0 : 22)
        }
        ForEach(host.sections) { section in
            if section.isPlugin {
                Section {
                    ForEach(section.rows) { RowLine(row: $0, server: server.id).opacity(dim) }
                } header: {
                    GroupLabel(title: section.name)
                }
            } else {
                // Without a main row, the repo's rows sit right under its label.
                Section {
                    if let main = section.main {
                        MainCard(row: main, server: server.id).opacity(dim)
                    } else {
                        ForEach(section.others) { RowLine(row: $0, server: server.id).opacity(dim) }
                    }
                } header: {
                    RepoLabel(name: section.name)
                }
                if section.main != nil, !section.others.isEmpty {
                    Section {
                        ForEach(section.others) { RowLine(row: $0, server: server.id).opacity(dim) }
                    }
                }
            }
        }
    }

    /// What a server with no rows to show says in their place.
    @ViewBuilder private var empty: some View {
        if let problem = host.problem {
            Label(problem.title, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        } else if server.isUnreachable {
            Label("Can't reach \(server.name)", systemImage: "wifi.slash")
                .foregroundStyle(.secondary)
        } else if host.isLoading || !server.isConnected {
            ProgressView().frame(maxWidth: .infinity)
        } else {
            Text("No rows").foregroundStyle(.secondary)
        }
    }
}

/// A server's name, its kind's symbol, and whether it is connected, above its repos.
private struct HostLabel: View {
    var server: ServerConnection

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: server.isBox ? "server.rack" : "laptopcomputer")
                .foregroundStyle(.secondary)
            Text(server.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(uiColor: .label))
            Spacer()
            Circle().fill(color).frame(width: 6, height: 6)
            Text(status).foregroundStyle(.secondary)
        }
        .font(.footnote)
        .textCase(nil)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("host-\(server.name)")
    }

    private var color: Color {
        switch server.status {
        case .connected: Theme.green
        case .connecting: Theme.yellow
        case .unreachable, .unpaired: Color.secondary
        }
    }

    private var status: String {
        switch server.status {
        case .connected: "connected"
        case .connecting: "connecting"
        case .unreachable:
            server.inboxAsOf.map { "as of \($0.formatted(date: .omitted, time: .shortened))" } ?? "out of reach"
        case .unpaired: "not paired"
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
                .foregroundStyle(Color(uiColor: .label))
        }
        .textCase(nil)
        .padding(.leading, -4)
    }
}

/// A repo's own checkout, larger than its other rows.
private struct MainCard: View {
    var row: PhoneRow
    var server: String

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
        .opens(row.lead.map { PaneRef(server: server, pane: $0.pane) })
    }

    private var line: String {
        guard let lead = row.lead else { return "No agent running" }
        return lead.lastLine ?? lead.state.phrase.capitalizedFirst
    }
}

private struct RowLine: View {
    var row: PhoneRow
    var server: String

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
        .opens(row.lead.map { PaneRef(server: server, pane: $0.pane) })
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
