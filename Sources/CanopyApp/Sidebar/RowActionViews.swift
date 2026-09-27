import CanopyCore
import SwiftUI

struct NewRowSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let repo: RepoSnapshot
    @State private var branch = ""
    @State private var base = ""
    @State private var isCreating = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Row in \(repo.name)")
                .font(.headline)
            Form {
                TextField("Branch", text: $branch, prompt: Text("feat/my-change"))
                TextField("Start from", text: $base, prompt: Text("origin's default branch"))
            }
            .formStyle(.columns)
            .disabled(isCreating)
            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if isCreating {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Row", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedBranch.isEmpty || isCreating)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var trimmedBranch: String {
        branch.trimmingCharacters(in: .whitespaces)
    }

    private func create() {
        isCreating = true
        error = nil
        let base = base.trimmingCharacters(in: .whitespaces)
        Task {
            error = await model.createRow(in: repo, branch: trimmedBranch, base: base.isEmpty ? nil : base)
            isCreating = false
            if error == nil {
                dismiss()
            }
        }
    }
}

struct RemoveRowPopover: View {
    @Environment(AppModel.self) private var model
    let row: Row
    @Binding var isPresented: Bool
    @State private var deleteBranch = false
    @State private var isDirty = false
    @State private var teardownCode: Int32?
    @State private var isWorking = false
    @State private var error: String?

    private var isAdopted: Bool { row.rowClass == .adopted }

    /// Read while the popover lays itself out, so its height includes the note.
    private var busyTerminals: Int { model.terminals.busyPanes(inRow: row.path).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isAdopted ? "Hide \(row.displayName)?" : "Remove \(row.displayName)?")
                .font(.headline)
            Text(
                isAdopted
                    ? "The worktree stays where it is and moves back to Other worktrees."
                    : "This deletes the worktree folder."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if !isAdopted, let branch = row.branch {
                Toggle("Also delete branch \(branch)", isOn: $deleteBranch)
            }
            if busyTerminals > 0 {
                NoteLine(
                    systemImage: "apple.terminal",
                    text: busyTerminals == 1
                        ? "A terminal in this row is running a program. Removing stops it."
                        : "\(busyTerminals) terminals in this row are running programs. Removing stops them.",
                    color: .secondary
                )
            }
            if isDirty {
                NoteLine(
                    systemImage: "exclamationmark.triangle.fill", text: "It has uncommitted changes.", color: .orange)
            }
            if let teardownCode {
                NoteLine(
                    systemImage: "exclamationmark.triangle.fill",
                    text: "Teardown failed with exit code \(teardownCode). Its tab shows why.",
                    color: .orange
                )
            }
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
                Button(buttonTitle, role: .destructive, action: remove)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking)
            }
        }
        .padding(14)
        .frame(width: 300)
        // The popover inherits the sidebar row's one-line limit.
        .lineLimit(nil)
    }

    private var buttonTitle: String {
        if isDirty || teardownCode != nil { return "Remove Anyway" }
        return isAdopted ? "Hide" : "Remove"
    }

    private func remove() {
        isWorking = true
        error = nil
        Task {
            switch await model.removeRow(
                row, force: isDirty, skipTeardown: teardownCode != nil, deleteBranch: deleteBranch)
            {
            case .removed: isPresented = false
            case .dirty: isDirty = true
            case .teardownFailed(let code): teardownCode = code
            case .failed(let message): error = message
            }
            isWorking = false
        }
    }
}

/// An icon and a sentence that wraps, for notes in narrow popovers.
struct NoteLine: View {
    let systemImage: String
    let text: String
    let color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: systemImage)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(color)
    }
}
