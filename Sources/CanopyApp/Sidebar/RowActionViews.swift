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
    @State private var isWorking = false
    @State private var error: String?

    private var isAdopted: Bool { row.rowClass == .adopted }

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
            if isDirty {
                Label("It has uncommitted changes.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
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
                Button(isDirty ? "Force Remove" : isAdopted ? "Hide" : "Remove", role: .destructive, action: remove)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func remove() {
        isWorking = true
        error = nil
        Task {
            switch await model.removeRow(row, force: isDirty, deleteBranch: deleteBranch) {
            case .removed: isPresented = false
            case .dirty: isDirty = true
            case .failed(let message): error = message
            }
            isWorking = false
        }
    }
}
