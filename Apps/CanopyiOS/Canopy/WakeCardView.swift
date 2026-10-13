import CanopyPhone
import SwiftUI

/// A box out of reach that the phone can start: off with Wake, waking with how long ago it started, or what went
/// wrong with Wake again.
struct WakeCardView: View {
    @Environment(PhoneApp.self) private var app
    var card: Waker.Card

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                detail
            }
            Spacer(minLength: 0)
            if !waking {
                Button(isFailed ? "Wake again" : "Wake") {
                    Task { await app.waker.wake(card.server) }
                }
                .buttonStyle(ChipStyle(kind: .solid))
                .accessibilityIdentifier("wake-\(card.server.name)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.card, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5))
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wake-card-\(card.server.name)")
    }

    private var waking: Bool {
        switch card.step {
        case .starting, .connecting: true
        case .failed, nil: false
        }
    }

    private var isFailed: Bool {
        if case .failed = card.step { return true }
        return false
    }

    @ViewBuilder private var icon: some View {
        if waking {
            ProgressView().frame(width: 22)
        } else {
            Image(systemName: isFailed ? "exclamationmark.triangle.fill" : "power")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isFailed ? Theme.red : Color.secondary)
                .frame(width: 22)
        }
    }

    private var title: String {
        switch card.step {
        case nil: "\(card.server.name) is off"
        case .starting, .connecting: "Waking \(card.server.name)"
        case .failed(let problem): problem.title
        }
    }

    @ViewBuilder private var detail: some View {
        switch card.step {
        case nil:
            Text("Wake starts it, and Canopy connects once it is up.").font(.footnote).foregroundStyle(.secondary)
        case .starting(let since), .connecting(let since):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(verbatim: "Started \(Int(max(0, context.date.timeIntervalSince(since)))) s ago")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        case .failed(let problem):
            if !problem.detail.isEmpty {
                Text(problem.detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
