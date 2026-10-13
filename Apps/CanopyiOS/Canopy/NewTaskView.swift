import CanopyPhone
import SwiftUI

/// New task: where, which repo and branch, and the brief the server's agent starts with. Start opens its conversation.
struct NewTaskView: View {
    @Environment(PhoneApp.self) private var app
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isTyping: Bool
    var started: (PaneRef) -> Void

    var body: some View {
        @Bindable var model = app.newTask
        NavigationStack {
            Form {
                if let problem = model.problem {
                    Section {
                        Banner(problem: problem, tint: Theme.red, icon: "exclamationmark.circle.fill") {
                            model.dismissProblem()
                        }
                        .padding(.horizontal, -16)
                        .padding(.bottom, -6)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                Section("Where") {
                    ForEach(model.choices) { choice in
                        WhereLine(choice: choice, isChosen: choice.id == model.serverID) {
                            model.serverID = choice.id
                            model.chose()
                        }
                    }
                }
                Section("Task") {
                    if model.repos.isEmpty {
                        TextField("Repo", text: $model.repo)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($isTyping)
                            .accessibilityIdentifier("task-repo")
                    } else {
                        Picker("Repo", selection: $model.repo) {
                            ForEach(model.repos, id: \.self) { Text($0).tag($0) }
                        }
                        .accessibilityIdentifier("task-repo")
                    }
                    TextField("Branch", text: $model.branch, prompt: Text("feat/new-thing"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($isTyping)
                        .accessibilityIdentifier("task-branch")
                    TextField("From", text: $model.base, prompt: Text("From origin's default branch"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($isTyping)
                        .accessibilityIdentifier("task-base")
                }
                Section {
                    TextField("What should the agent do?", text: $model.brief, axis: .vertical)
                        .lineLimit(4...12)
                        .focused($isTyping)
                        .accessibilityIdentifier("task-brief")
                } header: {
                    Text("Brief")
                } footer: {
                    if let command = model.agentCommand {
                        Text("Runs \(Text(command).font(.footnote.monospaced())) with the brief.")
                    }
                }
            }
            .scrollDismissesKeyboard(.immediately)
            .disabled(model.phase != .editing)
            .navigationTitle("New task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Return in the brief starts a new line, so the keyboard needs a way away.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { isTyping = false }
                        .accessibilityIdentifier("keyboard-done")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        model.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.phase == .editing {
                        Button(model.startTitle) {
                            model.begin { pane in
                                dismiss()
                                started(pane)
                            }
                        }
                        .disabled(!model.canStart)
                        .accessibilityIdentifier("task-start")
                    } else {
                        ProgressView()
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let progress = model.progress {
                    Text(progress)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 8)
                        .accessibilityIdentifier("task-progress")
                }
            }
        }
        .onAppear { model.open() }
        .onDisappear { model.cancel() }
        // Repos can arrive after the sheet opens, as Rows refreshes.
        .onChange(of: model.repos) { model.chose() }
    }

}

/// A server Where offers: its kind's symbol, its name, whether Start can reach it, and a check when chosen.
private struct WhereLine: View {
    var choice: NewTaskModel.Choice
    var isChosen: Bool
    var choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 10) {
                Image(systemName: choice.server.isBox ? "server.rack" : "laptopcomputer")
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(choice.server.name).foregroundStyle(.primary)
                    Text(choice.status).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if isChosen {
                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Theme.accent)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!choice.isAvailable)
        .opacity(choice.isAvailable ? 1 : 0.45)
        .accessibilityIdentifier("where-\(choice.server.name)")
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }
}
