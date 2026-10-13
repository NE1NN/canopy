import CanopyCore
import SwiftUI

/// A chat tab: the conversation's title, the conversation, and the composer.
struct ChatView: View {
    @Environment(AppModel.self) private var model
    let pane: Pane
    let chat: ChatSession
    let path: String
    @State private var isAtBottom = true
    @State private var scrollRequest = 0

    var body: some View {
        VStack(spacing: 0) {
            ChatHeader(pane: pane)
            ZStack(alignment: .bottom) {
                ChatList(
                    chat: chat, rows: ChatRows.rows(for: chat), actions: actions, isAtBottom: $isAtBottom,
                    scrollToBottomRequest: scrollRequest)
                if !isAtBottom {
                    Button {
                        scrollRequest += 1
                    } label: {
                        Label("Jump to latest", systemImage: "arrow.down")
                            .font(.system(size: 11.5, weight: .medium))
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .background(.regularMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(ChatStyle.cardBorder))
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 8)
                }
            }
            ChatComposer(
                chat: chat, composers: model.chatComposers, paneID: pane.id, onTrust: actions.trust,
                onDeclineTrust: actions.declineTrust)
        }
        .background(ChatStyle.background)
        .environment(\.openURL, OpenURLAction { model.open($0) })
        .onAppear {
            chat.open()
            model.chatComposers.focus(pane.id)
        }
    }

    private var actions: ChatActions {
        ChatActions(
            trust: {
                Task {
                    do {
                        try await chat.grantTrust()
                        model.chatComposers.focus(pane.id)
                    } catch {
                        model.show("Canopy could not save Claude Code's trust for this folder: \(error)")
                    }
                }
            },
            declineTrust: { model.terminals.closePane(pane.id) })
    }
}

/// The conversation's title, with the agent's state beside it.
private struct ChatHeader: View {
    let pane: Pane

    var body: some View {
        HStack(spacing: 8) {
            PaneStatusMark(pane: pane)
                .frame(width: 12)
            Text(pane.title)
                .font(.system(size: 11.5))
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: Style.webTabHeaderHeight)
        .background(Style.chrome)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.separator).frame(height: 1)
        }
    }
}
