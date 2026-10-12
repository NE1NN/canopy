import CanopyPhone
import CanopyWire
import SwiftUI

/// A pane's agent: its conversation as text, or its terminal, with the reply box and answers to its prompt.
struct ConversationView: View {
    @State private var conversation: ConversationModel
    @State private var terminal: TerminalModel

    init(app: PhoneApp, pane: String) {
        _conversation = State(initialValue: ConversationModel(connection: app.connection, pane: pane))
        _terminal = State(initialValue: TerminalModel(connection: app.connection, pane: pane))
    }

    var body: some View {
        @Bindable var conversation = conversation
        VStack(spacing: 0) {
            Picker("View", selection: $conversation.tab) {
                Text("Chat").tag(ConversationModel.Tab.chat)
                Text("Terminal").tag(ConversationModel.Tab.terminal)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .accessibilityIdentifier("tabs")
            if conversation.paneGone {
                Banner(
                    problem: PhoneProblem(title: "This pane closed.", detail: "What it showed stays here."),
                    tint: Theme.yellow
                )
                .padding(.top, 6)
            }
            switch conversation.tab {
            case .chat:
                ChatView(model: conversation)
            case .terminal:
                TerminalView(model: terminal)
            }
        }
        .background(Theme.background)
        .toolbar(.hidden, for: .tabBar)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(conversation.row?.name ?? conversation.pane)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 5) {
                        if let dot = conversation.agent?.dot {
                            AgentDotView(dot: dot, small: true).frame(width: 7, height: 7)
                        }
                        Text(conversation.paneGone ? "closed" : (conversation.agent?.state ?? .none).phrase)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("title")
            }
            if let row = conversation.row {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("More", systemImage: "ellipsis") {
                        PinButton(row: row)
                    }
                }
            }
        }
        .onAppear {
            conversation.start()
            if conversation.tab == .terminal { terminal.start() }
        }
        // The screen streams only while it shows, as it changes up to four times a second.
        .onChange(of: conversation.tab) { _, tab in
            if tab == .terminal { terminal.start() } else { terminal.stop() }
        }
        .onDisappear {
            conversation.stop()
            terminal.stop()
        }
    }
}

private struct ChatView: View {
    var model: ConversationModel
    @FocusState private var replying: Bool

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if model.older != nil {
                    if model.olderFailed {
                        Button("Couldn't load earlier messages. Try again") { Task { await model.loadOlder() } }
                            .font(.footnote)
                            .frame(maxWidth: .infinity)
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .onAppear { Task { await model.loadOlder() } }
                    }
                }
                ForEach(model.entries) { entry in
                    EntryView(entry: entry)
                }
                if let pending = model.pending {
                    PendingBubble(pending: pending)
                }
                if let note = model.chatNote {
                    Text(note)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                        .accessibilityIdentifier("chat-note")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .accessibilityIdentifier("chat")
        // Scrolling the conversation puts the keyboard away.
        .onScrollPhaseChange { _, phase in
            if phase == .interacting { replying = false }
        }

        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                PromptBar(model: model)
                Composer(model: model, focused: $replying)
            }
        }
    }
}

private struct EntryView: View {
    var entry: TranscriptEntry

    var body: some View {
        switch entry.kind {
        case .prompt:
            Bubble(text: entry.text)
        case .text:
            Text(markdown(entry.text))
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tools:
            HStack(spacing: 6) {
                Circle()
                    .fill(entry.failed ? Theme.red : Theme.green)
                    .frame(width: 5, height: 5)
                Text(entry.text)
                    .lineLimit(2)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        case .question:
            Card(label: "Question", tint: Theme.yellow) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array((entry.questions ?? []).enumerated()), id: \.offset) { _, question in
                        Text(question.question)
                    }
                    if entry.questions?.isEmpty != false { Text(entry.text) }
                    if let answer = entry.answer {
                        Text("Answered: \(answer)").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        case .plan:
            Card(label: "Plan", tint: Theme.accent) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(markdown(entry.text))
                    if let answer = entry.answer {
                        Text(answer).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        case .notice:
            Text(entry.text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
    }
}

private func markdown(_ text: String) -> AttributedString {
    (try? AttributedString(
        markdown: text,
        options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)))
        ?? AttributedString(text)
}

/// What the author said, on the right in the accent's blue.
private struct Bubble: View {
    var text: String
    var faded = false

    var body: some View {
        Text(text)
            .font(.body)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Theme.accent.opacity(faded ? 0.7 : 1),
                in: UnevenRoundedRectangle(
                    topLeadingRadius: 17, bottomLeadingRadius: 17, bottomTrailingRadius: 4, topTrailingRadius: 17)
            )
            .containerRelativeFrame(.horizontal, alignment: .trailing) { width, _ in width * 0.78 }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .textSelection(.enabled)
    }
}

private struct PendingBubble: View {
    var pending: ConversationModel.PendingReply

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Bubble(text: pending.text, faded: true)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("reply-state")
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var caption: String {
        switch pending.state {
        case .sending: "Sending"
        case .sent: "Sent"
        case .delivered: "Delivered"
        }
    }
}

/// A tinted card with a small label, for questions and plans.
private struct Card<Content: View>: View {
    var label: String
    var tint: Color
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(0.5)
                .foregroundStyle(tint)
            content
                .font(.body)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.45), lineWidth: 0.5))
    }
}

/// Answers to the open prompt: a question's options, Allow and Deny, or a plan's approval.
private struct PromptBar: View {
    var model: ConversationModel

    var body: some View {
        if let prompt = model.prompt, prompt.kind != .reply {
            VStack(alignment: .leading, spacing: 8) {
                switch prompt.kind {
                case .question:
                    questions(prompt)
                case .permission:
                    if let detail = prompt.detail {
                        Text(prompt.tool.map { "\($0): \(detail)" } ?? detail)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    HStack(spacing: 8) {
                        Button("Allow") { Task { await model.allow() } }.buttonStyle(ChipStyle(kind: .solid))
                            .accessibilityIdentifier("prompt-allow")
                        Button("Deny") { Task { await model.deny() } }.buttonStyle(ChipStyle(kind: .plain))
                            .accessibilityIdentifier("prompt-deny")
                    }
                case .plan:
                    HStack(spacing: 8) {
                        Button("Approve") { Task { await model.allow() } }.buttonStyle(ChipStyle(kind: .solid))
                        Button("Keep planning") { Task { await model.deny() } }.buttonStyle(ChipStyle(kind: .plain))
                    }
                case .reply:
                    EmptyView()
                }
                if let problem = model.answerProblem {
                    Text(problem.title)
                        .font(.footnote)
                        .foregroundStyle(Theme.red)
                        .accessibilityIdentifier("answer-problem")
                }
            }
            .disabled(model.isAnswering)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        }
    }

    @ViewBuilder
    private func questions(_ prompt: OpenPrompt) -> some View {
        let questions = prompt.questions ?? []
        let single = questions.count == 1 && !questions[0].multiSelect
        ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
            if !single {
                Text(question.header ?? question.question)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            FlowLayout(spacing: 6) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { option, choice in
                    Button(choice.label) { Task { await model.choose(question: index, option: option) } }
                        .buttonStyle(
                            ChipStyle(
                                kind: .tinted,
                                selected: model.selections.indices.contains(index)
                                    && model.selections[index].contains(option))
                        )
                        .accessibilityIdentifier("option-\(choice.label)")
                }
            }
        }
        if !single {
            Button("Send answers") { Task { await model.submitAnswers() } }
                .buttonStyle(ChipStyle(kind: .solid))
                .disabled(!model.canSubmitAnswers)
        }
    }
}

/// The reply box, with the reason a reply failed above it.
private struct Composer: View {
    @Bindable var model: ConversationModel
    var focused: FocusState<Bool>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let problem = model.replyProblem {
                HStack(alignment: .top) {
                    Text(problem.title).font(.footnote).foregroundStyle(Theme.red)
                    Spacer()
                    Button("Dismiss", systemImage: "xmark") { model.dismissReplyProblem() }
                        .labelStyle(.iconOnly)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("reply-problem")
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Reply to \(model.row?.name ?? "the agent")", text: $model.draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused(focused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.card, in: .rect(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.separator, lineWidth: 0.5))
                    .accessibilityIdentifier("reply")
                Button {
                    Task { await model.send() }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(model.canSend ? Theme.accent : Color.secondary.opacity(0.4), in: .circle)
                }
                .disabled(!model.canSend)
                .accessibilityLabel("Send")
                .accessibilityIdentifier("send")
            }
        }
        .disabled(model.paneGone)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Theme.background)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Lays chips out in rows, wrapping as they run out of width.
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(
            width: rows.map(\.width).max() ?? 0,
            height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(bounds.width, subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var items: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            let gap = rows[rows.count - 1].items.isEmpty ? 0 : spacing
            rows[rows.count - 1].items.append(index)
            rows[rows.count - 1].width += gap + size.width
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}
