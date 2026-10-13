import CanopyPhone
import CanopyWire
import SwiftUI

struct InboxView: View {
    @Environment(PhoneApp.self) private var app
    @State private var showsSettings = false
    @State private var path: [PaneRef] = []

    private var model: InboxModel { app.inbox }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                } header: {
                    ConnectionLine()
                }
                InboxSection(title: "Needs you", items: model.sections.needsYou)
                DoneSection(items: model.sections.done)
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            .opacity(model.isStale ? 0.55 : 1)
            .overlay {
                if model.hasInbox, model.sections.isEmpty {
                    CaughtUp(detail: model.caughtUpDetail)
                        .opacity(model.isStale ? 0.55 : 1)
                } else if !model.hasInbox, model.connectionLine.state == .unreachable {
                    ContentUnavailableView(
                        model.connectionLine.text, systemImage: "wifi.slash",
                        description: Text(verbatim: PhoneProblemText.checkTailscale))
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    if let problem = model.staleBanner {
                        Banner(problem: problem, tint: Theme.yellow, icon: "wifi.slash")
                    }
                    // A pairing link opened while paired fails here, since Pairing is not on screen.
                    if let problem = app.pairing.problem {
                        Banner(problem: problem, tint: Theme.red, icon: "exclamationmark.circle.fill") {
                            app.pairing.dismissProblem()
                        }
                    }
                    if let notice = model.notice {
                        Banner(problem: notice, tint: Theme.red, icon: "exclamationmark.circle.fill") {
                            model.dismissNotice()
                        }
                    }
                }
            }
            .navigationTitle("Inbox")
            .backButtonTitle("Inbox")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { showsSettings = true }
                        .accessibilityIdentifier("settings")
                }
            }
            .navigationDestination(for: PaneRef.self) { ref in
                PaneDestination(ref: ref)
            }
            .refreshable { app.servers.foreground() }
            .sheet(isPresented: $showsSettings) {
                SettingsView()
            }
        }
        .environment(\.openPane, OpenPaneAction { path.append($0) })
    }
}

/// Pushes a pane's conversation onto the tab's navigation stack.
struct OpenPaneAction {
    var open: @MainActor (PaneRef) -> Void

    @MainActor func callAsFunction(_ pane: PaneRef) {
        open(pane)
    }
}

extension EnvironmentValues {
    @Entry var openPane = OpenPaneAction { _ in }
}

extension View {
    /// The whole row opens the pane, while buttons inside it keep their own taps.
    func opens(_ pane: PaneRef?) -> some View {
        modifier(OpensPane(pane: pane))
    }
}

private struct OpensPane: ViewModifier {
    @Environment(\.openPane) private var openPane
    var pane: PaneRef?

    func body(content: Content) -> some View {
        content
            .contentShape(.rect)
            .onTapGesture { if let pane { openPane(pane) } }
            .accessibilityAddTraits(pane == nil ? [] : .isButton)
    }
}

enum PhoneProblemText {
    static let checkTailscale =
        "Check that Tailscale is on, on this iPhone and the server, and that the server is awake with Canopy running."
}

/// "Studio connected", which servers are out of reach, or when the inbox is from while all of them are.
struct ConnectionLine: View {
    @Environment(PhoneApp.self) private var app

    var body: some View {
        let line = app.inbox.connectionLine
        HStack(spacing: 6) {
            Circle().fill(color(line.state)).frame(width: 6, height: 6)
            Text(line.text)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .textCase(nil)
        .padding(.leading, -4)
        .accessibilityIdentifier("connection")
    }

    private func color(_ state: InboxModel.ConnectionLine.State) -> Color {
        switch state {
        case .connected: Theme.green
        case .connecting: Theme.yellow
        case .unreachable: Color.secondary
        }
    }
}

/// The mockup's group label: small and uppercase, with the group's count on the right.
struct GroupLabel: View {
    var title: String
    var count: Int?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let count { Text(verbatim: "\(count)") }
        }
        .font(.footnote)
        .textCase(.uppercase)
        .foregroundStyle(.secondary)
    }
}

struct Banner: View {
    var problem: PhoneProblem
    var tint: Color
    var icon = "exclamationmark.triangle.fill"
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .font(.subheadline.weight(.semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text(problem.title).font(.subheadline.weight(.semibold))
                if !problem.detail.isEmpty {
                    Text(problem.detail).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if let dismiss {
                Button("Dismiss", systemImage: "xmark", action: dismiss)
                    .labelStyle(.iconOnly)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(tint.opacity(0.12), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.4), lineWidth: 0.5))
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("banner")
    }
}

/// The empty Inbox: nothing waits, with how many agents still run and the way to them.
private struct CaughtUp: View {
    @Environment(\.showRows) private var showRows
    var detail: String

    var body: some View {
        ContentUnavailableView {
            Label("All caught up", systemImage: "checkmark.circle")
                .accessibilityIdentifier("caught-up")
        } description: {
            Text(detail)
        } actions: {
            Button("See rows") { showRows() }
                .buttonStyle(ChipStyle(kind: .tinted))
                .accessibilityIdentifier("see-rows")
        }
    }
}

/// Done agents, newest first, each read by opening it, swiping it, or Mark all read.
private struct DoneSection: View {
    @Environment(PhoneApp.self) private var app
    var items: [InboxItem]

    var body: some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { item in
                    InboxItemRow(item: item)
                        .swipeActions(edge: .trailing) {
                            Button("Mark read", systemImage: "checkmark") {
                                Task { await app.inbox.markRead(item) }
                            }
                            .tint(Theme.accent)
                            .disabled(item.server.isUnreachable)
                            .accessibilityIdentifier("mark-read-\(item.row.name)")
                        }
                }
            } header: {
                HStack {
                    Text("Done")
                    Spacer()
                    Button("Mark all read") { Task { await app.inbox.markAllRead() } }
                        .textCase(nil)
                        .foregroundStyle(Theme.accent)
                        .disabled(app.inbox.isStale)
                        .accessibilityIdentifier("mark-all-read")
                }
                .font(.footnote)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            }
        }
    }
}

private struct InboxSection: View {
    var title: String
    var items: [InboxItem]

    var body: some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { item in
                    InboxItemRow(item: item)
                }
            } header: {
                GroupLabel(title: title, count: items.count)
            }
        }
    }
}

/// One agent: its dot, row name, time, last line, and Allow and Deny for a permission prompt.
private struct InboxItemRow: View {
    @Environment(PhoneApp.self) private var app
    var item: InboxItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            AgentDotView(dot: item.agent.dot ?? (item.agent.state == .done ? .done : nil))
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    RowName(row: item.row, label: app.inbox.label(for: item.row))
                        .accessibilityIdentifier("item-\(item.row.name)")
                    Spacer(minLength: 8)
                    TimeAgo(since: item.agent.since)
                }
                if let line = item.agent.lastLine {
                    Text(line)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if item.agent.prompt?.kind == .permission {
                    AllowDeny(item: item)
                        .padding(.top, 6)
                }
            }
        }
        .padding(.vertical, 1)
        // An item from a server out of reach is as of when it last answered.
        .opacity(item.server.isUnreachable && !app.inbox.isStale ? 0.55 : 1)
        .opens(item.ref)
    }
}

struct AllowDeny: View {
    @Environment(PhoneApp.self) private var app
    var item: InboxItem

    var body: some View {
        HStack(spacing: 8) {
            Button("Allow") { Task { await app.inbox.answer(item, allow: true) } }
                .buttonStyle(ChipStyle(kind: .solid))
                .accessibilityIdentifier("allow-\(item.row.name)")
            Button("Deny") { Task { await app.inbox.answer(item, allow: false) } }
                .buttonStyle(ChipStyle(kind: .plain))
                .accessibilityIdentifier("deny-\(item.row.name)")
        }
        .disabled(app.inbox.answering.contains(item.ref) || item.server.isUnreachable)
    }
}

/// A repo's initial on its color, with the row's dot on its corner when it has one.
struct RepoTile: View {
    var name: String
    var dot: AgentDot?
    var size: CGFloat = 30

    var body: some View {
        Text(verbatim: String(name.first.map { String($0).uppercased() } ?? "?"))
            .font(.system(size: size * 0.47, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Theme.tile(for: name), in: .rect(cornerRadius: size * 0.27))
            .overlay(alignment: .topTrailing) {
                if let dot {
                    AgentDotView(dot: dot, small: true)
                        .background(Circle().fill(Theme.card).frame(width: 10, height: 10))
                        .offset(x: 5, y: -5)
                }
            }
    }
}

struct RowName: View {
    var row: PhoneRow
    var label: String?
    var muted = false
    var weight: Font.Weight = .semibold

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(row.name)
                .font(.body.weight(muted ? .regular : weight))
                .foregroundStyle(muted ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let label {
                Text(label)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

struct TimeAgo: View {
    var since: Double

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(verbatim: RelativeTime.short(since: since, now: context.date))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

/// The mockup's rounded buttons: solid for the main choice, tinted for options, plain for the rest.
struct ChipStyle: ButtonStyle {
    enum Kind {
        case solid, tinted, plain
    }

    var kind: Kind
    var selected = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let solid = kind == .solid || selected
        configuration.label
            .font(.subheadline.weight(kind == .plain && !selected ? .medium : .semibold))
            .padding(.horizontal, 15)
            .padding(.vertical, 6)
            .foregroundStyle(solid ? Color.white : kind == .tinted ? Theme.accent : Color.primary)
            .background(
                solid ? Theme.accent : kind == .tinted ? Theme.chip : Theme.fill, in: .capsule
            )
            .opacity(configuration.isPressed ? 0.6 : isEnabled ? 1 : 0.45)
            .contentShape(.capsule)
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
