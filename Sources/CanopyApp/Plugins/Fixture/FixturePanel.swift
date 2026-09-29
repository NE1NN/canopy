import CanopyCore
import SwiftUI

/// The fixture plugin's plain panel: what it wrote about the item, where the row's folder is, and the item's linked
/// rows.
struct FixturePanel: View {
    let row: PluginRow
    @State private var lines: [String] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    if let label = row.look.label {
                        Text(verbatim: label)
                            .font(Style.body.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(row.look.accessories.enumerated()), id: \.offset) { _, accessory in
                        PluginAccessoryView(accessory: accessory)
                    }
                    if row.isMissing {
                        TagView(text: "missing")
                    }
                }
                Text(lines.first.map { String($0.drop { $0 == "#" || $0 == " " }) } ?? row.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(lines.dropFirst().enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(Style.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Folder")
                        .font(Style.label)
                        .tracking(Style.labelTracking)
                        .textCase(.uppercase)
                        .foregroundStyle(.tertiary)
                    Text(verbatim: (row.path as NSString).abbreviatingWithTildeInPath)
                        .font(Style.meta)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                LinkedRowsView(plugin: row.plugin, item: row.item)
                    .padding(.horizontal, -8)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: row.path) {
            let text = (try? String(contentsOfFile: row.path + "/item.md", encoding: .utf8)) ?? ""
            lines = text.split(separator: "\n").map(String.init)
        }
    }
}
