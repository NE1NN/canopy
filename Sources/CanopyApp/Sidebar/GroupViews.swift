import CanopyCore
import SwiftUI

/// A group's header: a chevron that folds it, its name, and its row count, which gives way to `…` and `+` on hover.
struct GroupHeaderView: View {
    @Environment(AppModel.self) private var model
    let repo: RepoSnapshot
    let group: GroupSnapshot
    let count: Int
    let isFocused: Bool
    var isDropTarget = false
    let onNewRow: () -> Void
    @State private var isHovering = false
    @State private var isRenaming = false
    @State private var isConfirmingDelete = false

    /// A collapsed group shows the most urgent agent dot among the rows it hides.
    private var agentDot: AgentDot? {
        guard group.collapsed else { return nil }
        return model.terminals.agentDot(inRows: repo.rows(inGroup: group.name).map(\.path))
    }

    /// A collapsed group shows the selection for the row it hides, so the sidebar always says where the window is.
    private var holdsSelection: Bool {
        model.selectionFold == .group(repoPath: repo.path, name: group.name)
    }

    var body: some View {
        HStack(spacing: 8) {
            DisclosureChevron(isExpanded: !group.collapsed)
            Text(group.name)
                .font(Style.body.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if let agentDot {
                AgentDotView(dot: agentDot)
            }
            if isHovering || isRenaming || isConfirmingDelete {
                IconMenu(title: "More for \(group.name)", systemImage: "ellipsis") {
                    GroupMenuItems(rename: { isRenaming = true }, delete: requestDelete)
                }
                IconButton(title: "New Row in \(group.name)…", systemImage: "plus", action: onNewRow)
            } else {
                Text(verbatim: "\(count)")
                    .font(Style.meta)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 5)
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, 3)
        .frame(height: Style.rowHeight)
        .background(fill, in: RoundedRectangle(cornerRadius: Style.cornerRadius))
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { isHovering = $0 }
        .help(group.name)
        .contextMenu { GroupMenuItems(rename: { isRenaming = true }, delete: requestDelete) }
        .popover(isPresented: $isRenaming, arrowEdge: .trailing) {
            GroupNamePopover(
                title: "Rename \(group.name)", actionTitle: "Rename", name: group.name, isPresented: $isRenaming
            ) { name in
                await model.renameGroup(group, in: repo, to: name)
            }
        }
        .popover(isPresented: $isConfirmingDelete, arrowEdge: .trailing) {
            DeleteGroupPopover(group: group, count: count, isPresented: $isConfirmingDelete) {
                model.removeGroup(group, in: repo)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(group.name), group, \(count == 1 ? "1 row" : "\(count) rows")"
                + (agentDot.map { ", \($0.label.lowercased())" } ?? "")
        )
        .accessibilityValue(group.collapsed ? "Collapsed" : "Expanded")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { toggle() }
    }

    private var fill: Color {
        if isDropTarget { return Style.focusedSelectionFill }
        if holdsSelection { return isFocused ? Style.focusedSelectionFill : Style.selectionFill }
        return isHovering ? Style.hoverFill : .clear
    }

    private func toggle() {
        model.setCollapsed(group, !group.collapsed, in: repo)
    }

    /// An empty group goes at once. One with rows asks first.
    private func requestDelete() {
        if count == 0 {
            model.removeGroup(group, in: repo)
        } else {
            isConfirmingDelete = true
        }
    }
}

struct GroupMenuItems: View {
    let rename: () -> Void
    let delete: () -> Void

    var body: some View {
        Button("Rename…", action: rename)
        Button("Delete Group…", action: delete)
    }
}

/// Names a new group or renames one. A name the rules refuse shows why under the field and keeps the popover open.
struct GroupNamePopover: View {
    let title: String
    let actionTitle: String
    @State var name: String
    @Binding var isPresented: Bool
    /// Returns an error message to show, or nil once done.
    let commit: (String) async -> String?
    @State private var error: String?
    @State private var isWorking = false

    init(
        title: String, actionTitle: String, name: String = "", isPresented: Binding<Bool>,
        commit: @escaping (String) async -> String?
    ) {
        self.title = title
        self.actionTitle = actionTitle
        self._name = State(initialValue: name)
        self._isPresented = isPresented
        self.commit = commit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            TextField("Group name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle, action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
            }
        }
        .padding(14)
        .frame(width: 260)
        // The popover inherits the sidebar row's one-line limit.
        .lineLimit(nil)
    }

    private func save() {
        guard !isWorking else { return }
        isWorking = true
        Task {
            error = await commit(name)
            isWorking = false
            if error == nil {
                isPresented = false
            }
        }
    }
}

struct DeleteGroupPopover: View {
    let group: GroupSnapshot
    let count: Int
    @Binding var isPresented: Bool
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Delete \(group.name)?")
                .font(.headline)
            Text(
                count == 1
                    ? "Its row moves out of the group. No worktree is touched."
                    : "Its \(count) rows move out of the group. No worktree is touched."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive) {
                    isPresented = false
                    delete()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 280)
        .lineLimit(nil)
    }
}

/// A row's context menu: Prune for a missing row, and Move to Group for Canopy and adopted rows.
struct RowMenuItems: View {
    @Environment(AppModel.self) private var model
    let row: Row
    let onNewGroup: () -> Void

    private var repo: RepoSnapshot? { model.snapshot.repo(path: row.repoPath) }

    var body: some View {
        if row.isMissing, let repo {
            Button("Prune Missing Worktrees") { model.prune(repo) }
        }
        if row.rowClass == .canopy || row.rowClass == .adopted {
            Menu("Move to Group") {
                ForEach(repo?.groups ?? []) { group in
                    // Picking the row's own group, the checked one, changes nothing.
                    Toggle(
                        group.name,
                        isOn: Binding(
                            get: { row.group == group.name }, set: { _ in model.move(row, to: .group(group.name)) }))
                }
                if row.group != nil {
                    Divider()
                    Button("No Group") { model.move(row, to: .ungrouped) }
                }
                if repo?.groups.isEmpty == false {
                    Divider()
                }
                Button("New Group…", action: onNewGroup)
            }
        }
    }
}
