import CanopyCore
import SwiftUI

/// One field for `owner/repo` or a URL, with the user's GitHub repos below it to pick from.
struct CloneRepoSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var clone = CloneRepoState()
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        @Bindable var clone = clone
        VStack(alignment: .leading, spacing: 12) {
            Text("Clone Repo")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 5) {
                TextField("Repo", text: $clone.source, prompt: Text("owner/repo or URL"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .focused($isFieldFocused)
                    .onSubmit(start)
                    .disabled(clone.isCloning)
                // Always one line, so the list does not jump when a destination appears.
                Text(destination ?? hint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            GitHubRepoList(
                listing: clone.listing, repos: clone.repos, chosen: clone.source, canClone: destination != nil,
                pick: { clone.source = $0.nameWithOwner }
            )
            // Gives way to the progress bar or an error, so the sheet keeps its size.
            .frame(maxHeight: .infinity)
            .disabled(clone.isCloning)
            if clone.isCloning {
                CloneProgressView(source: clone.source, progress: clone.progress)
            }
            if let error = clone.error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    clone.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Clone", action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(destination == nil || clone.isCloning)
            }
        }
        .padding(20)
        .frame(width: 500, height: 480)
        .task { await clone.load(from: model) }
        .onAppear { isFieldFocused = true }
        .onChange(of: clone.isCloning) {
            if !clone.isCloning { isFieldFocused = true }
        }
        .onDisappear { clone.cancel() }
    }

    /// owner/repo needs gh, so without it only a URL will do.
    private var hint: String {
        switch clone.listing {
        case .success: "Pick one of your repos below, or type any owner/repo or URL."
        case .failure(.ghMissing), .failure(.notLoggedIn): "Paste the repo's URL."
        case .failure, nil: "Type owner/repo or a URL."
        }
    }

    private var destination: String? {
        model.cloneFolder(for: clone.source).map { "Clones into \(($0 as NSString).abbreviatingWithTildeInPath)" }
    }

    private func start() {
        guard destination != nil else { return }
        clone.start(with: model) { dismiss() }
    }
}

/// The sheet's state, kept out of the view so progress from the clone can reach it.
@MainActor
@Observable
final class CloneRepoState {
    var source = ""
    private(set) var listing: Result<[GitHubRepoSummary], GHFailure>?
    private(set) var isCloning = false
    private(set) var progress: CloneProgress?
    private(set) var error: AttributedString?
    @ObservationIgnored private var cloning: Task<Void, Never>?

    var repos: [GitHubRepoSummary] {
        guard case .success(let repos) = listing else { return [] }
        return GitHubRepoSummary.filter(repos, by: source)
    }

    func load(from model: AppModel) async {
        listing = await model.gitHubRepos()
    }

    func start(with model: AppModel, then done: @escaping @MainActor () -> Void) {
        guard !isCloning else { return }
        isCloning = true
        progress = nil
        error = nil
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        cloning = Task {
            do {
                try await model.cloneRepo(text) { progress in
                    Task { @MainActor [weak self] in
                        guard self?.isCloning == true else { return }
                        self?.progress = progress
                    }
                }
                done()
            } catch WorkspaceError.cloneCancelled {
                // Cancel closed the sheet already.
            } catch {
                self.error = Self.message(for: error, source: text)
            }
            isCloning = false
        }
    }

    /// The sheet has no `--into`, so errors that suggest it point at the CLI instead, with the command set as code.
    /// Everything else, including git's and gh's own words, is shown as it is.
    static func message(for error: any Error, source: String) -> AttributedString {
        let into = code("canopy repo clone \(source) --into <folder>")
        switch error as? WorkspaceError {
        case .folderTaken(let path, let holding)?:
            let what = holding.map { "already holds \($0)" } ?? "is already there and not empty"
            let folder = (path as NSString).abbreviatingWithTildeInPath
            return AttributedString("\(folder) \(what), so Canopy left it alone. To clone somewhere else, run ") + into
                + AttributedString(".")
        case .cloneNeedsFolder?:
            return AttributedString("Canopy cannot tell which folder \(source) goes in. Run ") + into
                + AttributedString(".")
        case .ghUnavailable(let fix)?:
            return (try? AttributedString(markdown: fix)) ?? AttributedString(fix)
        case let other?:
            return AttributedString(other.message)
        case nil:
            return AttributedString("\(error)")
        }
    }

    private static func code(_ text: String) -> AttributedString {
        var code = AttributedString(text)
        code.inlinePresentationIntent = .code
        return code
    }

    /// Stops a clone under way, which deletes what it wrote.
    func cancel() {
        cloning?.cancel()
    }
}

/// The user's repos, newest push first, or why they cannot be listed.
struct GitHubRepoList: View {
    let listing: Result<[GitHubRepoSummary], GHFailure>?
    let repos: [GitHubRepoSummary]
    let chosen: String
    /// Whether what was typed can be cloned, so an empty list can say Return still works.
    let canClone: Bool
    let pick: (GitHubRepoSummary) -> Void

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }

    @ViewBuilder private var content: some View {
        switch listing {
        case nil:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading your repos…")
                    .foregroundStyle(.secondary)
            }
        case .failure(let failure):
            Label {
                Text((try? AttributedString(markdown: failure.repoListNote)) ?? AttributedString(failure.repoListNote))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            .foregroundStyle(.secondary)
            .padding(24)
        case .success where repos.isEmpty:
            Text(canClone ? "None of your repos match. Press Return to clone it anyway." : "None of your repos match.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(24)
        case .success:
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(repos) { repo in
                        GitHubRepoLine(
                            repo: repo, isChosen: repo.nameWithOwner.caseInsensitiveCompare(chosen) == .orderedSame,
                            pick: { pick(repo) })
                    }
                }
                .padding(4)
            }
        }
    }
}

struct GitHubRepoLine: View {
    let repo: GitHubRepoSummary
    let isChosen: Bool
    let pick: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 8) {
                Image(systemName: repo.isPrivate ? "lock" : "book.closed")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    name
                        .font(Style.row)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let description = repo.description, !description.isEmpty {
                        Text(description)
                            .font(Style.meta)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let pushedAt = repo.pushedAt {
                    Text(pushedAt, format: .relative(presentation: .named))
                        .font(Style.meta)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
            .background(fill, in: RoundedRectangle(cornerRadius: Style.cornerRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    private var accessibilityLabel: String {
        var parts = [repo.nameWithOwner]
        if repo.isPrivate { parts.append("private") }
        if let description = repo.description, !description.isEmpty { parts.append(description) }
        if let pushedAt = repo.pushedAt {
            parts.append("pushed \(pushedAt.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: ", ")
    }

    /// The owner dimmed before the repo's own name.
    private var name: Text {
        let parts = repo.nameWithOwner.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return Text(verbatim: repo.nameWithOwner) }
        return Text(verbatim: parts[0] + "/").foregroundStyle(.secondary) + Text(verbatim: parts[1])
    }

    private var fill: Color {
        if isChosen { return Style.selectionFill }
        return isHovering ? Style.hoverFill : .clear
    }
}

struct CloneProgressView: View {
    let source: String
    let progress: CloneProgress?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Cloning \(source)…")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if let progress {
                    Text(verbatim: "\(progress.phase) \(progress.percent)%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            if let progress {
                ProgressView(value: progress.fraction)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
        }
    }
}
