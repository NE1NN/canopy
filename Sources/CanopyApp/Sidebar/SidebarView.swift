import CanopyCore
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var folderRequest = FolderRequest.addRepo
    @State private var isChoosingFolder = false
    @State private var newRowRepo: RepoSnapshot?

    enum FolderRequest {
        case addRepo
        case locate(RepoSnapshot)
    }

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedRowPath) {
            ForEach(model.snapshot.repos) { repo in
                Section {
                    ForEach(repo.rows) { row in
                        RowLineView(row: row, shortcut: model.shortcut(for: row), removable: row.rowClass != .main)
                            .tag(row.path)
                            .contextMenu {
                                if row.isMissing {
                                    Button("Prune Missing Worktrees") { model.prune(repo) }
                                }
                            }
                    }
                    if !repo.external.isEmpty {
                        DisclosureGroup("Other worktrees (\(repo.external.count))") {
                            ForEach(repo.external) { row in
                                RowLineView(row: row, shortcut: nil, removable: false)
                                    .tag(row.path)
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                } header: {
                    RepoHeaderView(
                        repo: repo,
                        onNewRow: { newRowRepo = repo },
                        onLocate: { chooseFolder(for: .locate(repo)) }
                    )
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.snapshot.repos.isEmpty {
                ContentUnavailableView {
                    Label("No Repos", systemImage: "folder.badge.plus")
                } description: {
                    Text("Add a git repository to see its worktrees.")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                chooseFolder(for: .addRepo)
            } label: {
                Label("Add Repo", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $newRowRepo) { repo in
            NewRowSheet(repo: repo)
        }
        // SwiftUI resets isPresented before calling the completion, so the request lives in its own state.
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                switch folderRequest {
                case .addRepo: model.addRepo(url)
                case .locate(let repo): model.relocateRepo(repo, to: url)
                }
            case .failure(let error):
                model.show(error)
            }
        }
    }

    private func chooseFolder(for request: FolderRequest) {
        folderRequest = request
        isChoosingFolder = true
    }
}

struct RepoHeaderView: View {
    @Environment(AppModel.self) private var model
    let repo: RepoSnapshot
    let onNewRow: () -> Void
    let onLocate: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(repo.name)
            if repo.isMissing {
                TagView(text: "missing")
            }
            if let error = repo.error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help(error)
            }
            Spacer(minLength: 4)
            if !repo.isMissing {
                Button(action: onNewRow) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New row in \(repo.name)")
                .opacity(isHovering ? 1 : 0)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            if !repo.isMissing {
                Button("New Row…", action: onNewRow)
            }
            if repo.isMissing {
                Button("Locate…", action: onLocate)
            }
            Divider()
            Button("Remove Repo from Canopy") { model.removeRepo(repo) }
        }
    }
}

struct RowLineView: View {
    let row: Row
    let shortcut: Int?
    let removable: Bool
    @State private var isHovering = false
    @State private var isConfirmingRemove = false

    var body: some View {
        HStack(spacing: 6) {
            BranchIcon(color: row.isMissing ? .secondary : .green)
            Text(row.displayName)
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
            if isHovering || isConfirmingRemove {
                if let shortcut {
                    Text("⌘\(shortcut)")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                if removable {
                    Button {
                        isConfirmingRemove = true
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(row.rowClass == .adopted ? "Hide from Canopy" : "Remove row")
                    .popover(isPresented: $isConfirmingRemove, arrowEdge: .trailing) {
                        RemoveRowPopover(row: row, isPresented: $isConfirmingRemove)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .help(row.path)
    }
}

struct TagView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
    }
}
