import SwiftUI

/// Follows a remote row's name: a server and the host's name, quieter than the name itself. When the name leaves no
/// room for the host's, the server shows alone, and hovering names the host.
struct RemoteMark: View {
    let host: String
    let path: String?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 3) {
                server
                Text(host)
                    .font(Style.meta)
                    .lineLimit(1)
                    .fixedSize()
            }
            server
        }
        .foregroundStyle(.secondary)
        .help(path.map { "On \(host): \($0)" } ?? "On \(host)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("on \(host)")
    }

    private var server: some View {
        Image(systemName: "server.rack")
            .font(.system(size: 9, weight: .medium))
            .fixedSize()
    }
}
