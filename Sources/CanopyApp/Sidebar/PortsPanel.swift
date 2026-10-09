import CanopyCore
import SwiftUI

/// The ports rows' processes listen on, grouped by row, at the bottom of the sidebar.
struct PortsPanel: View {
    @Environment(AppModel.self) private var model

    private var count: Int { (model.ports ?? []).reduce(0) { $0 + $1.ports.count } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { model.portsCollapsed.toggle() }
            } label: {
                SectionLabel(title: "Ports", count: count > 0 ? count : nil) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(model.portsCollapsed ? 0 : 90))
                        .frame(width: 22, height: 22)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(model.portsCollapsed ? "Show ports" : "Hide ports")

            if !model.portsCollapsed, let groups = model.ports {
                if groups.isEmpty {
                    Text("Nothing is listening in your rows.")
                        .font(Style.meta)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 8)
                        .padding(.bottom, 4)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(groups, id: \.rowPath) { group in
                                PortGroupView(group: group)
                            }
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    // As tall as its groups, up to a limit, so many ports scroll rather than squeeze the rows.
                    .frame(maxHeight: 220)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct PortGroupView: View {
    @Environment(AppModel.self) private var model
    let group: PortGroup
    @State private var isHovering = false

    private var row: SidebarRow? { model.snapshot.sidebarRow(path: group.rowPath) }
    private var name: String { row?.displayName ?? group.rowPath }
    private var host: String? { group.ports.first?.remote?.host }

    private var isStopping: Bool { group.ports.allSatisfy { model.isStopping($0, inRow: group.rowPath) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                Button {
                    model.reveal(group.rowPath)
                } label: {
                    HStack(spacing: 8) {
                        Group {
                            switch row {
                            case .worktree(let row)?:
                                RowMark(row: row)
                            case .plugin(let row)?:
                                if let info = model.snapshot.section(row.plugin)?.info {
                                    Image(systemName: info.symbol)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                            case nil:
                                EmptyView()
                            }
                        }
                        .frame(width: 16)
                        Text(name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .layoutPriority(1)
                        if let host {
                            RemoteMark(host: host, path: row?.worktree?.remotePath)
                        }
                        Spacer(minLength: 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show \(name)")
                if isHovering {
                    Button {
                        model.stop(group.ports, inRow: group.rowPath)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isStopping)
                    .help(stopHelp)
                }
            }
            .font(Style.body)
            .foregroundStyle(.secondary)
            .padding(.leading, 7)
            .padding(.trailing, 5)
            .frame(height: 24)
            .background(isHovering ? Style.hoverFill : .clear, in: RoundedRectangle(cornerRadius: Style.cornerRadius))
            .onHover { isHovering = $0 }
            // The stop button shows on hover only, so VoiceOver and the context menu reach it too.
            .accessibilityAction(named: "Stop Everything Listening Here") {
                model.stop(group.ports, inRow: group.rowPath)
            }
            .contextMenu {
                Button("Stop Everything Listening Here") { model.stop(group.ports, inRow: group.rowPath) }
                    .disabled(isStopping)
            }
            FlowLayout(spacing: 4) {
                ForEach(group.ports, id: \.port) { port in
                    PortBadge(port: port, rowPath: group.rowPath)
                }
            }
            .padding(.leading, 31)
            .padding(.bottom, 6)
        }
    }

    private var stopHelp: String {
        let what = group.ports.count == 1 ? "Stop what listens here" : "Stop everything listening here"
        return host.map { "\(what) on \($0)" } ?? what
    }
}

struct PortBadge: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let port: RowPort
    let rowPath: String
    @State private var isHovering = false

    private var isStopping: Bool { model.isStopping(port, inRow: rowPath) }
    private var showsStop: Bool { isHovering && !isStopping }
    /// A remote port without a forward cannot be opened here.
    private var isUnreachable: Bool { port.macPort == nil }

    var body: some View {
        HStack(spacing: 2) {
            Button {
                if let mac = port.macPort, let url = URL(string: "http://localhost:\(mac)") { openURL(url) }
            } label: {
                // The badge's padding is part of the label, so a click anywhere on the badge but `x` opens the port.
                Text(verbatim: port.label)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(isUnreachable ? .tertiary : .primary)
                    .padding(.leading, 7)
                    .padding(.trailing, showsStop ? 0 : 7)
                    .frame(height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(openHelp)
            if showsStop {
                Button {
                    model.stop([port], inRow: rowPath)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(stopHelp)
            }
        }
        .padding(.trailing, showsStop ? 3 : 0)
        .background(
            isHovering ? Style.selectionFill : Style.badgeFill, in: RoundedRectangle(cornerRadius: Style.badgeRadius)
        )
        .opacity(isStopping ? 0.4 : 1)
        .disabled(isStopping)
        .onHover { isHovering = $0 }
        .accessibilityAction(named: "Stop") { model.stop([port], inRow: rowPath) }
        .contextMenu {
            Button("Stop") { model.stop([port], inRow: rowPath) }
        }
    }

    // Tooltips are built as plain strings: in a string literal, SwiftUI would format the numbers, as in "3,000".

    /// The processes holding the port, such as "node (PID 812)" or "gunicorn (PIDs 90, 91, 92)".
    /// A remote port's processes are named with their host, whose PIDs they are.
    private var holders: String {
        let names = Set(port.processes.map(\.process)).sorted().joined(separator: ", ")
        let pids = port.processes.map { String($0.pid) }.joined(separator: ", ")
        let host = port.remote.map { " on \($0.host)" } ?? ""
        return "\(names) (\(port.processes.count == 1 ? "PID" : "PIDs") \(pids))\(host)"
    }

    private var openHelp: String {
        guard let mac = port.macPort else {
            return "\(holders). Not forwarded to this Mac: \(port.forwardProblem ?? "")"
        }
        return "\(holders). Opens http://localhost:\(mac)."
    }

    /// Stopping the processes closes every port they hold, so the tooltip says which.
    private var stopHelp: String {
        let others = model.otherPorts(of: port).map { String($0) }
        guard !others.isEmpty else { return "Stop \(holders)." }
        return "Stop \(holders). Its other \(others.count == 1 ? "port" : "ports"), \(others.joined(separator: ", ")), "
            + "close too."
    }
}

/// Lays views out left to right, starting a new line when one fills up.
struct FlowLayout: SwiftUI.Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) -> CGSize {
        let lines = arrange(subviews, width: proposal.width ?? .infinity)
        let width = lines.map { $0.width }.max() ?? 0
        return CGSize(width: width, height: lines.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) {
        for line in arrange(subviews, width: bounds.width) {
            for item in line.items {
                subviews[item.index].place(
                    at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + line.y), proposal: .unspecified)
            }
        }
    }

    private struct Line {
        var items: [(index: Int, x: CGFloat)] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: LayoutSubviews, width: CGFloat) -> [Line] {
        var lines: [Line] = []
        var line = Line()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let x = line.items.isEmpty ? 0 : line.width + spacing
            if !line.items.isEmpty, x + size.width > width {
                lines.append(line)
                line = Line(y: line.y + line.height + spacing)
                line.items.append((index, 0))
                line.width = size.width
                line.height = size.height
            } else {
                line.items.append((index, x))
                line.width = x + size.width
                line.height = max(line.height, size.height)
            }
        }
        if !line.items.isEmpty { lines.append(line) }
        return lines
    }
}
