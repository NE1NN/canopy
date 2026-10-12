import CanopyPhone
import SwiftUI

struct SettingsView: View {
    @Environment(PhoneApp.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsUnpair = false

    var body: some View {
        let settings = SettingsModel(connection: app.connection)
        @Bindable var lock = app.lock
        NavigationStack {
            Form {
                Section("Mac") {
                    LabeledContent("Name", value: settings.mac)
                    LabeledContent("Status", value: settings.statusText)
                    if let host = settings.host {
                        LabeledContent("Address") { Text(host).font(.footnote.monospaced()) }
                    }
                    if let address = settings.address {
                        LabeledContent("Tailscale IP") { Text(address).font(.footnote.monospaced()) }
                    }
                    if let version = settings.version {
                        LabeledContent("Canopy", value: version)
                    }
                }
                Section("This iPhone") {
                    if let phone = settings.phone {
                        LabeledContent("Paired as", value: phone)
                    }
                }
                Section {
                    Toggle("Lock with Face ID", isOn: $lock.isEnabled)
                        .disabled(!lock.canLock)
                        .accessibilityIdentifier("lock-toggle")
                } footer: {
                    Text(
                        lock.canLock
                            ? "Canopy locks when you come back to it after 5 minutes away."
                            : "Set a passcode in the iPhone's Settings to lock Canopy.")
                }
                Section {
                    Button("Unpair from \(settings.mac)", role: .destructive) { confirmsUnpair = true }
                        .accessibilityIdentifier("unpair")
                } footer: {
                    Text(settings.removeHint)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Unpair from \(settings.mac)?", isPresented: $confirmsUnpair, titleVisibility: .visible
            ) {
                Button("Unpair", role: .destructive) {
                    dismiss()
                    settings.unpair()
                }
            } message: {
                Text("This iPhone forgets the Mac. Pairing again needs canopy phone pair on the Mac.")
            }
        }
    }
}
