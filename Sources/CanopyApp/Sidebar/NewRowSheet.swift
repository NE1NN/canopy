import CanopyCore
import SwiftUI

/// One field over one list of the repo's open PRs and branches, ending in a line that makes a new branch. Picking an
/// item does what `canopy` would for it, which the primary button's help spells out.
struct NewRowSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let repo: RepoSnapshot
    @State var group: String?
    let picker: NewRowPicker
    @State private var isWorking = false
    @State private var error: String?
    /// The host the row is made on, or nil for this Mac.
    @State private var host: String?
    @FocusState private var isFieldFocused: Bool
    /// Hosts with a clone of the repo, which the Where pop-up offers.
    private let hosts: [String]

    init(repo: RepoSnapshot, group: String?, picker: NewRowPicker, hosts: HostsConfig) {
        self.repo = repo
        _group = State(initialValue: group)
        self.picker = picker
        self.hosts = hosts.hosts.filter { $0.value.clonePath(repoName: repo.name, repoPath: repo.path) != nil }.keys
            .sorted()
        let remembered = UserDefaults.standard.string(forKey: Self.whereKey(repo.path))
        _host = State(initialValue: remembered.flatMap { self.hosts.contains($0) ? $0 : nil })
    }

    static func whereKey(_ repoPath: String) -> String { "newRow.where.\(repoPath)" }

    /// What picking the selected item does where the row goes.
    private var action: NewRowAction? {
        guard let selected = picker.selectedAction else { return nil }
        return host == nil ? selected : selected.onHost()
    }

    var body: some View {
        @Bindable var picker = picker
        VStack(alignment: .leading, spacing: 12) {
            Text("New Row in \(repo.name)")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            TextField("Branch", text: $picker.text, prompt: Text("Branch, PR number, or new branch name"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .focused($isFieldFocused)
                .onKeyPress(.downArrow) {
                    picker.moveSelection(by: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    picker.moveSelection(by: -1)
                    return .handled
                }
                .onSubmit(runSelected)
            NewRowList(picker: picker, run: runSelected)
                .frame(maxHeight: .infinity)
                .disabled(isWorking)
            if let error {
                Text((try? AttributedString(markdown: error)) ?? AttributedString(error))
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                if !hosts.isEmpty {
                    Picker("Where", selection: $host) {
                        Text("This Mac").tag(String?.none)
                        Divider()
                        ForEach(hosts, id: \.self) { host in
                            Text(host).tag(Optional(host))
                        }
                    }
                    .fixedSize()
                    .help("Where the row's worktree and terminals live")
                    .onChange(of: host) {
                        UserDefaults.standard.set(host, forKey: Self.whereKey(repo.path))
                    }
                }
                if !repo.groups.isEmpty {
                    Picker("Group", selection: $group) {
                        Text("No Group").tag(String?.none)
                        Divider()
                        ForEach(repo.groups) { group in
                            Text(group.name).tag(Optional(group.name))
                        }
                    }
                    .fixedSize()
                    // Opening or adopting a row leaves it where it is.
                    .disabled(action.map { !$0.createsRow } ?? false)
                }
                if isWorking {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(primaryTitle, action: runSelected)
                    .keyboardShortcut(.defaultAction)
                    .disabled(action == nil || isWorking)
                    .help(
                        action?.command(repo: repo.name, host: host)
                            ?? (host.map { "A pull request opens as a row on this Mac for now, not on \($0)." } ?? ""))
            }
        }
        .padding(20)
        .frame(width: 560, height: 520)
        .task { await picker.load() }
        .onAppear { isFieldFocused = true }
    }

    private var primaryTitle: String {
        switch action {
        case .selectRow?: "Open Row"
        case .adopt?: "Adopt"
        default: "Create Row"
        }
    }

    private func runSelected() {
        guard !isWorking, let action = picker.selectedAction, self.action != nil else { return }
        isWorking = true
        error = nil
        Task {
            error = await model.run(action, in: repo, group: action.createsRow || host != nil ? group : nil, host: host)
            isWorking = false
            if error == nil {
                dismiss()
            }
        }
    }
}

/// The two sections and the new branch line, in one scrolling list that follows the selection.
private struct NewRowList: View {
    @Bindable var picker: NewRowPicker
    let run: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if picker.showsPullRequests {
                        SectionLabel(title: "Pull requests", count: count(picker.pullRequestItems)) {}
                        if let note = picker.pullRequestNote {
                            NoteRow(note: note)
                        }
                        ForEach(picker.pullRequestItems) { line(for: $0) }
                    }
                    SectionLabel(title: "Branches", count: count(picker.branchItems)) {
                        if picker.isFetching {
                            ProgressView()
                                .controlSize(.mini)
                                .help("Fetching origin")
                                .padding(.trailing, 5)
                        }
                    }
                    if let note = picker.branchNote {
                        NoteRow(note: note)
                    }
                    ForEach(picker.branchItems) { line(for: $0) }
                    if let item = picker.newBranchItem {
                        Divider().padding(.vertical, 4)
                        line(for: item)
                    }
                }
                .padding(4)
            }
            .onChange(of: picker.selectedItem?.id) {
                guard let id = picker.selectedItem?.id else { return }
                proxy.scrollTo(id)
            }
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }

    /// Sections say how many items they show, and nothing while they show only a note.
    private func count(_ items: [NewRowItem]) -> Int? {
        items.isEmpty ? nil : items.count
    }

    private func line(for item: NewRowItem) -> some View {
        ItemLine(
            item: item, isSelected: picker.selectedItem?.id == item.id, base: $picker.base,
            defaultBase: picker.defaultBase, select: { picker.select(item.id) }, run: run
        )
        .id(item.id)
    }
}

/// One PR, branch, or the new branch line. A click selects it and a double click picks it.
private struct ItemLine: View {
    let item: NewRowItem
    let isSelected: Bool
    @Binding var base: String
    let defaultBase: String?
    let select: () -> Void
    let run: () -> Void
    @State private var isHovering = false
    @FocusState private var isBaseFocused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            content
        }
        // Only the start point field takes clicks itself. Everything else lets them through to the fill below.
        .allowsHitTesting(isNewBranch)
        .padding(.horizontal, 8)
        .frame(height: height)
        // Clicks select and double clicks run from the fill, which sits behind the start point field rather than
        // around it, so a double click that selects a word there never runs the line.
        .background {
            RoundedRectangle(cornerRadius: Style.cornerRadius)
                .fill(fill)
                .contentShape(Rectangle())
                .onTapGesture(perform: select)
                .simultaneousGesture(TapGesture(count: 2).onEnded(run))
        }
        .onHover { isHovering = $0 }
        // The new branch line keeps its start point field reachable on its own.
        .accessibilityElement(children: isNewBranch ? .contain : .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction {
            select()
            run()
        }
    }

    private var isNewBranch: Bool {
        if case .newBranch = item { return true }
        return false
    }

    private var height: Double {
        if case .pullRequest = item { return 42 }
        return 28
    }

    private var fill: Color {
        if isSelected { return Style.focusedSelectionFill }
        return isHovering ? Style.hoverFill : .clear
    }

    @ViewBuilder private var content: some View {
        switch item {
        case .pullRequest(let pr):
            PullRequestGlyph()
                .mark(pr.state.color)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: "#\(pr.number)")
                        .font(Style.row.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(pr.title)
                        .font(Style.row)
                        .lineLimit(1)
                }
                HStack(spacing: 5) {
                    Text(pullRequestDetail(pr))
                        .font(Style.meta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if pr.state == .draft {
                        TagView(text: "draft")
                    }
                    if pr.isFork {
                        TagView(text: "fork")
                    }
                }
            }
            Spacer(minLength: 8)
            if let holder = pr.row {
                HolderTag(holder: holder)
            }
        case .branch(let branch):
            BranchGlyph()
                .mark(.secondary)
                .frame(width: 14)
            Text(branch.name)
                .font(Style.row)
                .lineLimit(1)
                .truncationMode(.middle)
            TagView(text: branch.label)
            Spacer(minLength: 8)
            if let holder = branch.row {
                HolderTag(holder: holder)
            }
            Text(ShortAge.text(branch.committedAt))
                .font(Style.meta)
                .foregroundStyle(.tertiary)
        case .newBranch(let name):
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14)
                .allowsHitTesting(false)
            (Text("New branch ") + Text(verbatim: "‘\(name)’").fontWeight(.medium) + Text(" from"))
                .font(Style.row)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
                .allowsHitTesting(false)
            TextField("Start from", text: $base, prompt: Text(verbatim: defaultBase ?? "origin's default branch"))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .labelsHidden()
                .frame(minWidth: 120, maxWidth: 200)
                .focused($isBaseFocused)
                .onChange(of: isBaseFocused) {
                    if isBaseFocused { select() }
                }
                .onSubmit(run)
            Spacer(minLength: 0)
        }
    }

    /// `head · author · 2h ago`.
    private func pullRequestDetail(_ pr: ListedPullRequest) -> String {
        var parts = [pr.headBranch]
        if let author = pr.author { parts.append(author) }
        parts.append(ShortAge.text(pr.updatedAt))
        return parts.joined(separator: " · ")
    }
}

/// "In row" for an item a row already has, which picking opens, or "Other worktree" for one another tool made.
private struct HolderTag: View {
    let holder: BranchHolder

    var body: some View {
        if holder.isRow {
            Text("In row")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 5)
                .frame(height: 15)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: Style.tagRadius))
        } else {
            TagView(text: "Other worktree")
        }
    }
}

/// Why a section is empty or may be out of date, or that it is loading.
private struct NoteRow: View {
    let note: NewRowPicker.Note

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            switch note.kind {
            case .loading:
                ProgressView().controlSize(.mini)
                    .frame(width: 14)
            case .warning:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .frame(width: 14)
            case .info:
                Color.clear.frame(width: 14, height: 1)
            }
            Text((try? AttributedString(markdown: note.text)) ?? AttributedString(note.text))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(Style.meta)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}
