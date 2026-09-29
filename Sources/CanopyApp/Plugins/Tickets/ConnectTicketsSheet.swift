import CanopyCore
import CanopyTickets
import SwiftUI

/// Connects Canopy to ticket-manager, as `canopy ticket connect` does: the address, a token, and optionally
/// ticket-manager's page for a ticket.
struct ConnectTicketsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let info: PluginInfo
    @State private var url = ""
    @State private var token = ""
    @State private var web = ""
    @State private var isWorking = false
    @State private var error: String?
    @FocusState private var isURLFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                PluginTile(info: info, size: 20)
                Text("Connect Tickets")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
            }
            Text(
                "Each Discord ticket you pick from ticket-manager becomes a row, with its conversation beside the row's terminals."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Address")
                        .gridColumnAlignment(.trailing)
                    TextField("Address", text: $url, prompt: Text(verbatim: "https://<deployment>.convex.site"))
                        .focused($isURLFocused)
                }
                GridRow {
                    Text("Token")
                    SecureField("Token", text: $token, prompt: Text("From npx convex run"))
                }
                GridRow {
                    Text("Ticket page")
                    TextField("Ticket page", text: $web, prompt: Text(verbatim: "Optional: https://…/tickets/{id}"))
                }
            }
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .disabled(isWorking)
            Text(
                "Make a token in ticket-manager with `npx convex run --prod api/apiTokens:create '{\"email\": \"<email>\", \"label\": \"canopy\"}'`. Canopy keeps it in the Keychain."
            )
            .font(Style.meta)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            if let error {
                Text((try? AttributedString(markdown: error)) ?? AttributedString(error))
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Text(verbatim: command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help("The canopy command that does the same, reading the token from the terminal")
                Spacer(minLength: 8)
                if isWorking {
                    ProgressView().controlSize(.small)
                }
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect", action: connect)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking || url.trimmingCharacters(in: .whitespaces).isEmpty || token.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 540)
        .onAppear { isURLFocused = true }
    }

    private var command: String {
        let address = url.trimmingCharacters(in: .whitespaces)
        var command = "canopy ticket connect " + (address.isEmpty ? "<url>" : NewRowAction.quoted(address))
        let page = web.trimmingCharacters(in: .whitespaces)
        if !page.isEmpty { command += " --web " + NewRowAction.quoted(page) }
        return command
    }

    private func connect() {
        isWorking = true
        error = nil
        let params = TicketConnectParams(url: url, token: token, web: web)
        Task {
            do {
                _ = try await model.plugins.call(
                    TicketMethod.connect, params: try .from(params), target: TargetHint(), row: nil)
                dismiss()
            } catch {
                self.error = PluginHost.message(error)
            }
            isWorking = false
        }
    }
}
