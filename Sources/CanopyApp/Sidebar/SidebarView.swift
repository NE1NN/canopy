import CanopyCore
import SwiftUI

/// Repos and their rows, drawn by Canopy rather than a `List` so hover, selection, and density follow `Style`.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var newRowRepo: RepoSnapshot?
    /// Repos whose other worktrees are shown.
    @State private var expanded: Set<String> = []
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
        .sheet(item: $newRowRepo) { repo in
            NewRowSheet(repo: repo)
        }
    }

    private var repoList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !model.snapshot.repos.isEmpty {
                    SectionLabel(title: "Repos") {
                        IconButton(title: "Add Repo…", systemImage: "plus", shortcut: "⇧⌘O") {
                            model.chooseFolder(for: .addRepo)
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
                        onNewRow: { newRowRepo = repo }
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
            // Fills the column even with no repos, so the empty state gets the whole width.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) {
            model.selectRow(offset: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            model.selectRow(offset: 1)
            return .handled
        }
        .overlay {
            if model.snapshot.repos.isEmpty {
                ContentUnavailableView {
                    Label("No Repos", systemImage: "folder.badge.plus")
                } description: {
                    Text("Add a git repository to see its worktrees.")
                } actions: {
                    Button("Add Repo…") { model.chooseFolder(for: .addRepo) }
                }
            }
        }
    }
}

/// A repo's header, its PR warning, its rows, and its other worktrees.
struct RepoSection: View {
    @Environment(AppModel.self) private var model
    let repo: RepoSnapshot
    @Binding var isExpanded: Bool
    let isFocused: Bool
    let onNewRow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RepoHeaderView(repo: repo, onNewRow: onNewRow)
            if let warning = repo.pullRequestWarning {
                RepoWarningView(text: warning)
            }
            ForEach(repo.rows) { row in
                RowLineView(
                    row: row, isSelected: row.path == model.selectedRowPath, isFocused: isFocused,
                    shortcut: model.shortcut(for: row), removable: row.rowClass != .main
                )
                .contextMenu {
                    if row.isMissing {
                        Button("Prune Missing Worktrees") { model.prune(repo) }
                    }
                }
            }
            if !repo.external.isEmpty {
                OtherWorktreesToggle(count: repo.external.count, isExpanded: $isExpanded)
                if isExpanded {
                    ForEach(repo.external) { row in
                        RowLineView(
                            row: row, isSelected: row.path == model.selectedRowPath, isFocused: isFocused,
                            shortcut: nil, removable: false)
                    }
                }
            }
        }
        .padding(.top, 4)
    }
}

struct RepoHeaderView: View {
    @Environment(AppModel.self) private var model
    let repo: RepoSnapshot
    let onNewRow: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            RepoTile(mark: repo.mark, isDimmed: repo.isMissing)
            Text(repo.name)
                .font(Style.body.weight(.semibold))
                .foregroundStyle(repo.isMissing ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
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
            if repo.isMissing {
                Button("Locate…") { model.chooseFolder(for: .locate(repo)) }
                    .controlSize(.small)
                    .help("Find where \(repo.name) moved")
                RepoMenu(repo: repo, onNewRow: onNewRow)
            } else if isHovering {
                RepoMenu(repo: repo, onNewRow: onNewRow)
                IconButton(title: "New Row in \(repo.name)…", systemImage: "plus", action: onNewRow)
            } else {
                Text(verbatim: "\(repo.rows.count)")
                    .font(Style.meta)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 5)
                    .accessibilityLabel(repo.rows.count == 1 ? "1 row" : "\(repo.rows.count) rows")
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, 3)
        .frame(height: Style.headerHeight)
        .background(isHovering ? Style.hoverFill : .clear, in: RoundedRectangle(cornerRadius: Style.cornerRadius))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu { RepoMenuItems(repo: repo, onNewRow: onNewRow) }
    }
}

/// The repo's `…` button, holding what its context menu holds.
struct RepoMenu: View {
    let repo: RepoSnapshot
    let onNewRow: () -> Void
    @State private var isHovering = false

    var body: some View {
        Menu {
            RepoMenuItems(repo: repo, onNewRow: onNewRow)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(width: 22, height: 22)
        .background(isHovering ? Style.hoverFill : .clear, in: RoundedRectangle(cornerRadius: 5))
        .foregroundStyle(isHovering ? .primary : .secondary)
        .onHover { isHovering = $0 }
        .help("More for \(repo.name)")
        .accessibilityLabel("More for \(repo.name)")
    }
}

struct RepoMenuItems: View {
    @Environment(AppModel.self) private var model
    let repo: RepoSnapshot
    let onNewRow: () -> Void

    var body: some View {
        if repo.isMissing {
            Button("Locate…") { model.chooseFolder(for: .locate(repo)) }
        } else {
            Button("New Row…", action: onNewRow)
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
    @State private var isHovering = false
    @State private var isConfirmingRemove = false

    private var isRunning: Bool { model.terminals.isRunningProgram(inRow: row.path) }

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
            if isRunning {
                RunningDot()
            }
            if let pr = row.pullRequest {
                PullRequestNumber(pr: pr)
            }
            if isHovering || isConfirmingRemove {
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
        .padding(.leading, 7)
        .padding(.trailing, 5)
        .frame(height: Style.rowHeight)
        .background(fill, in: RoundedRectangle(cornerRadius: Style.cornerRadius))
        .contentShape(Rectangle())
        .onTapGesture { model.selectedRowPath = row.path }
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
        return isHovering ? Style.hoverFill : .clear
    }

    private var accessibilityLabel: String {
        var parts = [row.displayName]
        if let pr = row.pullRequest { parts.append("pull request \(pr.number), \(pr.state.label)") }
        if isRunning { parts.append("running a program") }
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
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16)
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
