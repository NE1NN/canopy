import CanopyPhone
import SwiftUI

struct SettingsView: View {
    @Environment(PhoneApp.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var pairsAnother = false

    var body: some View {
        let settings = SettingsModel(servers: app.servers)
        let lock = app.lock
        NavigationStack {
            Form {
                Section {
                    ForEach(settings.list) { server in
                        NavigationLink {
                            ServerDetail(server: server) { settings.remove(id: server.id) }
                        } label: {
                            ServerLine(server: server)
                        }
                        .accessibilityIdentifier("server-\(server.name)")
                    }
                    Button("Pair another server", systemImage: "plus") { pairsAnother = true }
                        .accessibilityIdentifier("pair-another")
                } header: {
                    Text("Servers")
                } footer: {
                    Text(
                        "To add a host, run canopy phone pair --on <host> on the Mac. canopy phone pair pairs the Mac itself."
                    )
                }
                Section {
                    Toggle(
                        "Lock with Face ID",
                        isOn: Binding(get: { lock.isEnabled }, set: { on in Task { await lock.setEnabled(on) } })
                    )
                    .disabled(!lock.canLock)
                    .accessibilityIdentifier("lock-toggle")
                } footer: {
                    Text(
                        lock.canLock
                            ? "Canopy locks when you come back to it after 5 minutes away."
                            : "Set a passcode in the iPhone's Settings to lock Canopy.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $pairsAnother) {
                PairAnotherSheet()
            }
        }
    }
}

/// A server in the list: its kind's symbol, its name, and its status.
private struct ServerLine: View {
    var server: ServerSettings

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: server.isBox ? "server.rack" : "laptopcomputer")
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(server.name)
                Text(server.statusText).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ServerDetail: View {
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsRemove = false
    var server: ServerSettings
    var remove: () -> Void

    var body: some View {
        Form {
            Section {
                LabeledContent("Name", value: server.name)
                LabeledContent("Kind", value: server.kindText)
                LabeledContent("Status", value: server.statusText)
                LabeledContent("Address") { Text(server.host).font(.footnote.monospaced()) }
                if let address = server.address {
                    LabeledContent("Tailscale IP") { Text(address).font(.footnote.monospaced()) }
                }
                if let version = server.version {
                    LabeledContent("Canopy", value: version)
                }
            }
            Section("This iPhone") {
                LabeledContent("Paired as", value: server.phone)
            }
            Section {
                Button("Remove \(server.name)", role: .destructive) { confirmsRemove = true }
                    .accessibilityIdentifier("remove-server")
            } footer: {
                Text(server.removeHint)
            }
        }
        .navigationTitle(server.name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Remove \(server.name)?", isPresented: $confirmsRemove, titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                dismiss()
                remove()
            }
        } message: {
            Text("This iPhone forgets \(server.name). Pairing again needs canopy phone pair on the Mac.")
        }
    }
}

/// Pairing from Settings, which closes once a server is paired.
private struct PairAnotherSheet: View {
    @Environment(PhoneApp.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PairingView(addsAnother: true)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
        .onChange(of: app.pairing.lastPaired?.id) { dismiss() }
    }
}
