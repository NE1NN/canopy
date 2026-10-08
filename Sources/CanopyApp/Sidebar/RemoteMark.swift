import SwiftUI

/// Follows a remote row's name: a server and the host's name, quieter than the name itself.
struct RemoteMark: View {
    let host: String
    let path: String?

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "server.rack")
                .font(.system(size: 9, weight: .medium))
            Text(host)
                .font(Style.meta)
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .fixedSize()
        .help(path.map { "On \(host): \($0)" } ?? "On \(host)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("on \(host)")
    }
}
