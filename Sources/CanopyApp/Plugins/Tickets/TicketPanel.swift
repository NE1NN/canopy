import CanopyCore
import CanopyTickets
import SwiftUI

/// A ticket row's panel beside its terminals: the header, a banner when something is wrong, the conversation, then
/// when it was fetched.
struct TicketPanel: View {
    let row: PluginRow
    let tickets: TicketsPlugin

    var body: some View {
        let store = tickets.store
        let state = store.ticket(row.item)
        VStack(spacing: 0) {
            TicketHeader(row: row, summary: store.summary(row.item), web: store.summary(row.item).flatMap(store.webURL))
            Divider()
            if row.isMissing || state.isMissing {
                MissingBanner(row: row)
            } else if let failure = state.failure {
                FailureBanner(failure: failure, fetchedAt: state.fetchedAt)
            }
            if let detail = state.detail {
                TicketBody(row: row, detail: detail)
                    .id(row.path)
            } else {
                VStack(spacing: 8) {
                    if state.isFetching || state.failure == nil {
                        ProgressView().controlSize(.small)
                    }
                    Text(
                        state.isFetching || state.failure == nil
                            ? "Fetching the ticket…" : "No copy of this ticket yet."
                    )
                    .font(Style.body)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            TicketFooter(state: state) {
                Task { await tickets.refresh(row.item) }
            }
        }
    }
}

/// The ticket's name, status, customer, owner, how long the customer has waited, and where else it opens.
private struct TicketHeader: View {
    let row: PluginRow
    let summary: TicketSummary?
    let web: URL?
    @Environment(\.openURL) private var openURL
    @State private var isExplainingWeb = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(verbatim: summary?.name ?? row.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if let summary {
                HStack(spacing: 6) {
                    StatusTag(status: summary.status)
                    Text(verbatim: summary.customer)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let owner = summary.owner {
                        PluginAccessoryView(
                            accessory: .initials(
                                owner.initials, color: TicketLook.ownerColor(owner.email),
                                help: "Owned by \(owner.email)"))
                    }
                    Spacer(minLength: 4)
                    if summary.waiting {
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            Text("waiting \(TicketAge.span(from: summary.lastActivity, to: context.date))")
                                .foregroundStyle(Color(nsColor: .systemOrange))
                                .fontWeight(.medium)
                        }
                        .help("The customer spoke last and is waiting for a reply")
                    }
                }
                .font(Style.body)
                HStack(spacing: 6) {
                    OpenButton(title: "Discord", help: "Open the ticket's channel in Discord") {
                        if let url = URL(string: summary.discordUrl) { openURL(url) }
                    }
                    OpenButton(title: "ticket-manager", help: "Open the ticket in ticket-manager") {
                        if let web { openURL(web) } else { isExplainingWeb = true }
                    }
                    .popover(isPresented: $isExplainingWeb, arrowEdge: .bottom) {
                        Text(
                            "Canopy does not know ticket-manager's address for a ticket yet. Connect again with `canopy ticket connect <url> --web 'https://…/tickets/{id}'`, or set `web` in config.json's tickets section."
                        )
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(14)
                        .frame(width: 300)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OpenButton: View {
    let title: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(Style.meta.weight(.medium))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(help)
    }
}

/// open, closed, or archived, in the status's color.
struct StatusTag: View {
    let status: TicketStatus

    var body: some View {
        let color: Color = status == .open ? .green : .secondary
        Text(verbatim: status.text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .frame(height: 15)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: Style.tagRadius))
    }
}

/// The last fetch failed: what went wrong, and how old the ticket the panel shows is.
private struct FailureBanner: View {
    let failure: TicketFailure
    let fetchedAt: Date?

    var body: some View {
        Banner {
            Text((try? AttributedString(markdown: failure.message)) ?? AttributedString(failure.message))
            TimelineView(.periodic(from: .now, by: 5)) { context in
                Text(
                    fetchedAt.map { "Showing the copy from \(TicketAge.ago($0, now: context.date))." }
                        ?? "Canopy has no copy of this ticket yet."
                )
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// ticket-manager no longer has the ticket.
private struct MissingBanner: View {
    let row: PluginRow
    @State private var isConfirmingRemove = false

    var body: some View {
        Banner {
            Text("ticket-manager no longer has this ticket. Its folder and terminals stay until you remove the row.")
            Button("Remove Row…") { isConfirmingRemove = true }
                .controlSize(.small)
                .popover(isPresented: $isConfirmingRemove, arrowEdge: .bottom) {
                    RemovePluginRowPopover(row: row, isPresented: $isConfirmingRemove)
                }
        }
    }
}

private struct Banner<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                content
            }
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(Style.meta)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.orange.opacity(0.1))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// When the ticket was fetched, and a button that fetches it now.
private struct TicketFooter: View {
    let state: TicketViewState
    let refresh: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            TimelineView(.periodic(from: .now, by: 5)) { context in
                Text(state.fetchedAt.map { "Updated \(TicketAge.ago($0, now: context.date))" } ?? "Not fetched yet")
            }
            Spacer(minLength: 4)
            if state.isFetching {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 22, height: 22)
            } else {
                IconButton(title: "Refresh", systemImage: "arrow.clockwise", action: refresh)
            }
        }
        .font(Style.meta)
        .foregroundStyle(.secondary)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 32)
    }
}
