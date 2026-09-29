import CanopyCore
import SwiftUI

/// Repos and their rows, drawn by Canopy rather than a `List` so hover, selection, and density follow `Style`.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var newRow: NewRowRequest?
    /// Repos whose other worktrees are shown.
    @State private var expanded: Set<String> = []
    /// Where each line a dragged row can land sits in the list.
    @State private var dropSlots: [DropSlot] = []
    @State private var pluginSlots: [PluginDropSlot] = []
    @State private var pluginPicker: PluginPickerRequest?
    @FocusState private var isFocused: Bool

    var body: some View {
        // The ports panel sits below the list rather than over it, so rows never scroll under it.
        VStack(spacing: 0) {
            repoList
            // With no repos there are no rows to listen, so the empty state stands alone.
            if !model.snapshot.repos.isEmpty {
                Divider()
                PortsPanel()
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
            }
        }
        .sheet(item: $newRow) { request in
            NewRowSheet(repo: request.repo, group: request.group, picker: request.picker)
        }
        .sheet(item: $pluginPicker) { request in
            PluginPickerSheet(section: request.section, picker: request.picker)
        }
    }

    private var repoList: some View {
        ScrollViewReader { proxy in
            repoScroll
                // A row picked with ⌘1 to ⌘9 or `canopy row select` scrolls into view.
                .onChange(of: model.selectedRowPath) {
                    guard let path = model.selectedRowPath else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(path) }
                }
                // A row picked again from the ports panel or the CLI, perhaps just unfolded, scrolls into view too.
                .onChange(of: model.scrollRequest) {
                    guard let path = model.scrollRequest?.path else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(path) }
                }
        }
    }

    private var repoScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !model.snapshot.repos.isEmpty || !model.snapshot.activePlugins.isEmpty {
                    SectionLabel(title: "Repos") {
                        IconMenu(title: "Add", systemImage: "plus") {
                            Button("Add Local Repo…") { model.chooseFolder(for: .addRepo) }
                            Button("Clone from GitHub…", action: model.showCloneSheet)
                            PluginSetupItems()
                        }
                    }
                }
                ForEach(model.snapshot.repos) { repo in
                    RepoSection(
                        repo: repo,
                        isExpanded: Binding(
                            get: { expanded.contains(repo.path) },
                            set: { if $0 { expanded.insert(repo.path) } else { expanded.remove(repo.path) } }),
                        isFocused: isFocused,
                        onNewRow: {
                            newRow = NewRowRequest(
                                repo: repo, group: $0, picker: NewRowPicker(sources: model.newRowSources(for: repo)))
                        }
                    )
                }
                // Each plugin that is on, below the repos, in built-in order.
                ForEach(model.snapshot.activePlugins) { section in
                    PluginSectionView(section: section, isFocused: isFocused) {
                        if let picker = model.picker(for: section) {
                            pluginPicker = PluginPickerRequest(section: section, picker: picker)
                        }
                    }
                }
            }
            .coordinateSpace(.rowList)
            .onPreferenceChange(DropSlotsKey.self) { dropSlots = $0 }
            .onPreferenceChange(PluginDropSlotsKey.self) { pluginSlots = $0 }
            .overlay(alignment: .topLeading) {
                if let target = model.rowDropTarget {
                    RowDropIndicator(target: target, slots: dropSlots, pluginSlots: pluginSlots)
                }
            }
            .onDrop(
                of: [.canopyRow],
                delegate: RowDropDelegate(model: model, slots: dropSlots, pluginSlots: pluginSlots)
            )
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
            // Fills the column even with no repos, so the empty state gets the whole width.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onChange(of: isFocused) {
            if !isFocused { model.sidebarLostKeyboard() }
        }
        .onKeyPress(.upArrow) {
            model.selectRow(offset: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            model.selectRow(offset: 1)
            return .handled
        }
        .overlay {
            if model.snapshot.repos.isEmpty && model.snapshot.activePlugins.isEmpty {
                ContentUnavailableView {
                    Label("No Repos", systemImage: "folder.badge.plus")
                } description: {
                    Text("Add a git repository to see its worktrees.")
                } actions: {
                    Button("Add Repo…") { model.chooseFolder(for: .addRepo) }
                    ForEach(model.pluginSetups, id: \.id) { plugin in
                        Button(plugin.setup.title) { model.showSetup(of: plugin.id) }
                    }
                }
            }
        }
    }
}

/// What the New Row sheet opens on: a repo, and the group a group's `+` picked.
struct NewRowRequest: Identifiable {
    let repo: RepoSnapshot
    let group: String?
    /// Made here, once per sheet, since the sheet's view is made again whenever the sidebar updates.
    let picker: NewRowPicker

    var id: String { repo.path }
}

/// What a plugin's picker opens on, made once per sheet.
struct PluginPickerRequest: Identifiable {
    let section: PluginSection
    let picker: PluginPicker

    var id: String { section.id }
}

/// A repo's header, then, unless the repo is folded, its PR warning, its ungrouped rows, its groups, and its other
/// worktrees.
struct RepoSection: View {
    @Environment(AppModel.self) private var model
    let repo: RepoSnapshot
    @Binding var isExpanded: Bool
    let isFocused: Bool
    /// Opens the New Row sheet, on a group or on none.
    let onNewRow: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RepoHeaderView(repo: repo, isFocused: isFocused, onNewRow: { onNewRow(nil) })
            if !repo.collapsed {
                content
            }
        }
        .padding(.top, 4)
        // Folding a repo or a group arrives as a new snapshot, so the rows it shows or hides animate from here.
        .animation(.easeOut(duration: 0.15), value: repo.collapsed)
        .animation(.easeOut(duration: 0.15), value: repo.groups)
    }

    @ViewBuilder private var content: some View {
        if let warning = repo.pullRequestWarning {
            RepoWarningView(text: warning)
        }
        ForEach(repo.rows.filter { $0.group == nil }) { row in
            line(for: row)
        }
        // A missing repo shows no rows, so it shows no groups either.
        if !repo.isMissing {
            ForEach(repo.groups) { group in
                let rows = repo.rows(inGroup: group.name)
                GroupHeaderView(
                    repo: repo, group: group, count: rows.count, isFocused: isFocused,
                    isDropTarget: model.draggedRow?.repoPath == repo.path
                        && model.rowDropTarget?.indicator == .header(group.name),
                    onNewRow: { onNewRow(group.name) }
                )
                .dropSlot(repo: repo.path, .header(group.name))
                if !group.collapsed {
                    ForEach(rows) { row in
                        line(for: row, indent: Style.groupIndent)
                    }
                }
            }
        }
        if !repo.external.isEmpty {
            OtherWorktreesToggle(count: repo.external.count, isExpanded: $isExpanded)
            if isExpanded {
                ForEach(repo.external) { row in
                    RowLineView(
                        row: row, isSelected: row.path == model.selectedRowPath, isFocused: isFocused,
                        shortcut: nil, removable: false
                    )
                    .id(row.path)
                }
            }
        }
    }

    private func line(for row: Row, indent: Double = 0) -> some View {
        RowLineView(
            row: row, isSelected: row.path == model.selectedRowPath, isFocused: isFocused,
            shortcut: model.shortcut(for: row.path), removable: row.rowClass != .main, indent: indent
        )
        .dropSlot(repo: repo.path, row.rowClass == .main ? .main(row.path) : .row(row.path, group: row.group))
        .id(row.path)
    }
}

/// A repo's tile, name, and chevron, then its row count, which gives way to `…` and `+` on hover. Clicking it anywhere
/// else folds or unfolds the repo.
struct RepoHeaderView: View {
    @Environment(AppModel.self) private var model
    let repo: RepoSnapshot
    let isFocused: Bool
    let onNewRow: () -> Void
    @State private var isHovering = false
    @State private var isNamingGroup = false

    /// A folded repo shows the most urgent agent dot among the rows it hides.
    private var agentDot: AgentDot? {
        guard repo.collapsed else { return nil }
        return model.terminals.agentDot(inRows: repo.rows.map(\.path))
    }

    var body: some View {
        HStack(spacing: 8) {
            RepoTile(mark: repo.mark, isDimmed: repo.isMissing)
            // The tile holds the mark column, so the chevron follows the name and the tile still lines up with rows.
            HStack(spacing: 0) {
                Text(repo.name)
                    .font(Style.body.weight(.semibold))
                    .foregroundStyle(repo.isMissing ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                DisclosureChevron(isExpanded: !repo.collapsed)
            }
            if repo.isMissing {
                TagView(text: "missing")
            }
            if let error = repo.error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(Style.meta)
                    .foregroundStyle(.orange)
                    .help(error)
            }
            Spacer(minLength: 4)
            if let agentDot {
                AgentDotView(dot: agentDot)
            }
            if repo.isMissing {
                Button("Locate…") { model.chooseFolder(for: .locate(repo)) }
                    .controlSize(.small)
                    .help("Find where \(repo.name) moved")
                RepoMenu(repo: repo, onNewRow: onNewRow, onNewGroup: { isNamingGroup = true })
            } else if isHovering || isNamingGroup {
                RepoMenu(repo: repo, onNewRow: onNewRow, onNewGroup: { isNamingGroup = true })
                IconButton(title: "New Row in \(repo.name)…", systemImage: "plus", action: onNewRow)
            } else {
                Text(verbatim: "\(repo.rows.count)")
                    .font(Style.meta)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 5)
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, 3)
        .frame(height: Style.headerHeight)
        .background(fill, in: RoundedRectangle(cornerRadius: Style.cornerRadius))
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { isHovering = $0 }
        .contextMenu { RepoMenuItems(repo: repo, onNewRow: onNewRow, onNewGroup: { isNamingGroup = true }) }
        .popover(isPresented: $isNamingGroup, arrowEdge: .trailing) {
            GroupNamePopover(title: "New Group in \(repo.name)", actionTitle: "Create", isPresented: $isNamingGroup) {
                name in
                await model.createGroup(in: repo, name: name)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(repo.collapsed ? "Collapsed" : "Expanded")
        .accessibilityAddTraits(holdsSelection ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { toggle() }
        // The header reads as one button, so its own buttons are reached as named actions.
        .accessibilityActions {
            if repo.isMissing {
                Button("Locate…") { model.chooseFolder(for: .locate(repo)) }
            } else {
                Button("New Row…", action: onNewRow)
            }
        }
    }

    /// A folded repo holding the selected row shows the selection, so the sidebar always says where the window is.
    private var holdsSelection: Bool { model.selectionFold == .repo(repo.path) }

    private var fill: Color {
        if holdsSelection { return isFocused ? Style.focusedSelectionFill : Style.selectionFill }
        return isHovering ? Style.hoverFill : .clear
    }

    private var accessibilityLabel: String {
        var parts = [repo.name, "repo", repo.rows.count == 1 ? "1 row" : "\(repo.rows.count) rows"]
        if repo.isMissing { parts.append("missing") }
        if let agentDot { parts.append(agentDot.label.lowercased()) }
        return parts.joined(separator: ", ")
    }

    private func toggle() {
        model.setCollapsed(repo, !repo.collapsed)
    }
}

/// The repo's `…` button, holding what its context menu holds.
struct RepoMenu: View {
    let repo: RepoSnapshot
    let onNewRow: () -> Void
    let onNewGroup: () -> Void

    var body: some View {
        IconMenu(title: "More for \(repo.name)", systemImage: "ellipsis") {
            RepoMenuItems(repo: repo, onNewRow: onNewRow, onNewGroup: onNewGroup)
        }
    }
}

struct RepoMenuItems: View {
    @Environment(AppModel.self) private var model
    let repo: RepoSnapshot
    let onNewRow: () -> Void
    let onNewGroup: () -> Void

    var body: some View {
        if repo.isMissing {
            Button("Locate…") { model.chooseFolder(for: .locate(repo)) }
        } else {
            Button("New Row…", action: onNewRow)
            Button("New Group…", action: onNewGroup)
        }
        Divider()
        Button("Remove Repo from Canopy") { model.removeRepo(repo) }
    }
}

struct RowLineView: View {
    @Environment(AppModel.self) private var model
    let row: Row
    let isSelected: Bool
    let isFocused: Bool
    let shortcut: Int?
    let removable: Bool
    /// How far a row sits in from its repo's other rows, as inside a group.
    var indent = 0.0
    @State private var isHovering = false
    @State private var isConfirmingRemove = false
    @State private var isNamingGroup = false

    private var agentDot: AgentDot? { model.terminals.agentDot(inRow: row.path) }

    /// Hover stops updating during a drag, so the row being dragged drops its hover look itself.
    private var isDragged: Bool { model.isDraggingRowOverList && model.draggedRow?.path == row.path }

    var body: some View {
        HStack(spacing: 8) {
            RowMark(row: row)
                .frame(width: 16)
            Text(row.displayName)
                .font(Style.row)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(row.isMissing ? .secondary : .primary)
            if let tag = row.externalTag {
                TagView(text: tag.label)
            }
            if row.isMissing {
                TagView(text: "missing")
            }
            Spacer(minLength: 4)
            if let agentDot {
                AgentDotView(dot: agentDot)
            }
            if let link = row.link, let item = model.snapshot.pluginRow(plugin: link.plugin, item: link.item),
                let label = item.look.label
            {
                LinkChip(row: item, label: label)
            }
            if let pr = row.pullRequest {
                PullRequestNumber(pr: pr)
            }
            if (isHovering && !isDragged) || isConfirmingRemove {
                if let shortcut {
                    Text(verbatim: "⌘\(shortcut)")
                        .font(Style.meta)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                if removable {
                    Button {
                        isConfirmingRemove = true
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(row.rowClass == .adopted ? "Hide from Canopy" : "Remove row")
                    .popover(isPresented: $isConfirmingRemove, arrowEdge: .trailing) {
                        RemoveRowPopover(row: row, isPresented: $isConfirmingRemove)
                    }
                }
            }
        }
        .padding(.leading, 7 + indent)
        .padding(.trailing, 5)
        .frame(height: Style.rowHeight)
        .background(fill, in: RoundedRectangle(cornerRadius: Style.cornerRadius))
        .contentShape(Rectangle())
        .onTapGesture { model.selectedRowPath = row.path }
        .rowDragSource(row, model: model)
        // The dragged row dims in place while its image follows the pointer over the list.
        .opacity(isDragged ? 0.4 : 1)
        .contextMenu { RowMenuItems(row: row, onNewGroup: { isNamingGroup = true }) }
        .popover(isPresented: $isNamingGroup, arrowEdge: .trailing) {
            GroupNamePopover(title: "New Group", actionTitle: "Create and Move", isPresented: $isNamingGroup) { name in
                await model.createGroup(named: name, moving: row)
            }
        }
        .onHover { isHovering = $0 }
        // The PR number slides left as the shortcut and remove button come in.
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help(row.path)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.selectedRowPath = row.path }
    }

    private var fill: Color {
        if isSelected { return isFocused ? Style.focusedSelectionFill : Style.selectionFill }
        return isHovering && !isDragged ? Style.hoverFill : .clear
    }

    private var accessibilityLabel: String {
        var parts = [row.displayName]
        if let group = row.group { parts.append("in \(group)") }
        if let tag = row.externalTag { parts.append("from \(tag.label)") }
        if let pr = row.pullRequest { parts.append("pull request \(pr.number), \(pr.state.label)") }
        if let agentDot { parts.append(agentDot.label.lowercased()) }
        if row.isMissing { parts.append("missing") }
        return parts.joined(separator: ", ")
    }
}

/// Opens the PR on GitHub. The rest of the row still selects it.
struct PullRequestNumber: View {
    let pr: PullRequest
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if let url = URL(string: pr.url) { openURL(url) }
        } label: {
            Text(verbatim: "#\(pr.number)")
                .font(Style.meta.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(pr.state.color)
        }
        .buttonStyle(.plain)
        .help("\(pr.state.label): \(pr.title)")
        .accessibilityLabel("Pull request \(pr.number), \(pr.state.label). Opens on GitHub.")
    }
}

/// Worktrees made by other tools, folded under their repo.
struct OtherWorktreesToggle: View {
    let count: Int
    @Binding var isExpanded: Bool
    @State private var isHovering = false

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                DisclosureChevron(isExpanded: isExpanded)
                Text(count == 1 ? "1 other worktree" : "\(count) other worktrees")
                    .font(Style.body)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.leading, 7)
            .frame(height: 24)
            .background(isHovering ? Style.hoverFill : .clear, in: RoundedRectangle(cornerRadius: Style.cornerRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }
}

/// Why a repo shows no PR badges, with the fix. Long messages from gh stop at three lines, with the rest on hover.
struct RepoWarningView: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .frame(width: 16)
            Text((try? AttributedString(markdown: text)) ?? AttributedString(text))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(Style.meta)
        .padding(.leading, 7)
        .padding(.trailing, 5)
        .padding(.vertical, 3)
        .help(text)
    }
}

/// "Connect Tickets…" and the like, for each plugin that is off and turns on through a sheet.
struct PluginSetupItems: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let setups = model.pluginSetups
        if !setups.isEmpty {
            Divider()
            ForEach(setups, id: \.id) { plugin in
                Button(plugin.setup.title) { model.showSetup(of: plugin.id) }
            }
        }
    }
}
