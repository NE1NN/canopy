import CanopyCore
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var folderRequest: FolderRequest?

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
                        RowLineView(row: row, shortcut: model.shortcut(for: row))
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
                                RowLineView(row: row, shortcut: nil)
                                    .tag(row.path)
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                } header: {
                    RepoHeaderView(repo: repo) { folderRequest = .locate(repo) }
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
                folderRequest = .addRepo
            } label: {
                Label("Add Repo", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fileImporter(
            isPresented: Binding(get: { folderRequest != nil }, set: { if !$0 { folderRequest = nil } }),
            allowedContentTypes: [.folder]
        ) { result in
            guard case .success(let url) = result, let request = folderRequest else { return }
            switch request {
            case .addRepo: model.addRepo(url)
            case .locate(let repo): model.relocateRepo(repo, to: url)
            }
        }
    }
}

struct RepoHeaderView: View {
    @Environment(AppModel.self) private var model
    let repo: RepoSnapshot
    let onLocate: () -> Void

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
        }
        .contextMenu {
            if repo.isMissing {
                Button("Locate…", action: onLocate)
            }
            Button("Remove Repo from Canopy") { model.removeRepo(repo) }
        }
    }
}

struct RowLineView: View {
    let row: Row
    let shortcut: Int?
    @State private var isHovering = false

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
            if isHovering, let shortcut {
                Text("⌘\(shortcut)")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
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
