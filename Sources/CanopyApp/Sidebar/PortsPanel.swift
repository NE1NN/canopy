import CanopyCore
import SwiftUI

/// The ports rows' processes listen on, grouped by row, at the bottom of the sidebar.
struct PortsPanel: View {
    @Environment(AppModel.self) private var model

    private var count: Int { model.ports.reduce(0) { $0 + $1.ports.count } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { model.portsCollapsed.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(model.portsCollapsed ? 0 : 90))
                    Text("Ports")
                        .textCase(.uppercase)
                    if model.portsCollapsed, count > 0 {
                        Text(verbatim: "\(count)")
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(model.portsCollapsed ? "Show ports" : "Hide ports")

            if !model.portsCollapsed {
                if model.ports.isEmpty {
                    Text("Nothing is listening in your rows.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(model.ports, id: \.rowPath) { group in
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

    private var name: String { model.snapshot.row(path: group.rowPath)?.displayName ?? group.rowPath }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Button(name) { model.selectedRowPath = group.rowPath }
                    .buttonStyle(.plain)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("Show \(name)")
                Spacer(minLength: 4)
                Button {
                    model.stop(group.ports)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(group.ports.count == 1 ? "Stop what listens here" : "Stop everything listening here")
            }
            .font(.callout)
            FlowLayout(spacing: 4) {
                ForEach(group.ports, id: \.self) { port in
                    PortBadge(port: port)
                }
            }
        }
    }
}

struct PortBadge: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let port: ListeningPort

    private var isStopping: Bool { model.stoppingPorts.contains(port) }

    var body: some View {
        HStack(spacing: 3) {
            Button {
                if let url = URL(string: "http://localhost:\(port.port)") { openURL(url) }
            } label: {
                Text(verbatim: "\(port.port)")
                    .monospacedDigit()
            }
            .buttonStyle(.plain)
            .help("\(port.process) (PID \(port.pid)). Opens http://localhost:\(port.port).")
            Button {
                model.stop([port])
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(stopHelp)
        }
        .font(.caption)
        .padding(.leading, 7)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
        .opacity(isStopping ? 0.4 : 1)
        .disabled(isStopping)
    }

    /// Stopping the process closes every port it holds, so the tooltip says which.
    private var stopHelp: String {
        let others = model.otherPorts(of: port).map { "\($0)" }
        let base = "Stop \(port.process) (PID \(port.pid))"
        guard !others.isEmpty else { return base + "." }
        return base
            + ". Its other \(others.count == 1 ? "port" : "ports"), \(others.joined(separator: ", ")), close too."
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
