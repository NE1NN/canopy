import AppKit
import CanopyCore
import SwiftUI

/// A page Claude published: its snapshot, title, kind, and version, with Open beside and more. A version a later
/// publish replaced shows small and dimmed.
struct ArtifactCard: View {
    let artifact: ChatArtifact
    let thumbnail: URL?
    let actions: ChatActions

    var body: some View {
        if let newer = artifact.replacedBy {
            replaced(by: newer)
        } else {
            current
        }
    }

    private var current: some View {
        HStack(spacing: 12) {
            ArtifactThumbnail(file: thumbnail, width: 64, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(artifact.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ChatStyle.strongText)
                    .lineLimit(1)
                Text(details)
                    .font(.system(size: 11.5))
                    .foregroundStyle(ChatStyle.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let url = artifact.url {
                Button {
                    actions.openArtifact(artifact, .panel)
                } label: {
                    Label("Open beside", systemImage: "sidebar.right")
                        .font(.system(size: 11.5))
                        .foregroundStyle(ChatStyle.artifactLink)
                }
                .buttonStyle(.plain)
                Menu {
                    Button("Open in a Tab") { actions.openArtifact(artifact, .tab) }
                    Button("Open in Browser") { actions.openInBrowser(url) }
                    Divider()
                    Button("Copy Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }
                } label: {
                    Text(verbatim: "•••")
                        .font(.system(size: 12))
                        .foregroundStyle(ChatStyle.primaryText)
                        .frame(height: 26)
                        .padding(.horizontal, 10)
                        .background(ChatStyle.buttonFill, in: RoundedRectangle(cornerRadius: 7))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(10)
        .background(ChatStyle.artifactFill, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(ChatStyle.artifactBorder))
    }

    private var details: String {
        guard artifact.url != nil else { return "Publishing…" }
        let version = artifact.version.map { "version \($0)" }
        return ([artifact.type] + [version, artifact.isPrivate ? "private" : nil].compactMap { $0 })
            .joined(separator: " · ")
    }

    private func replaced(by newer: Int) -> some View {
        Button {
            actions.openArtifact(artifact, .panel)
        } label: {
            HStack(spacing: 10) {
                ArtifactThumbnail(file: thumbnail, width: 44, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(artifact.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(ChatStyle.primaryText)
                        .lineLimit(1)
                    Text("Version \(artifact.version ?? newer - 1) · replaced by version \(newer)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(ChatStyle.secondaryText)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(ChatStyle.replacedFill, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(ChatStyle.cardBorder))
        .help("Open the current version beside the chat")
    }
}

/// An artifact's snapshot, or tiles standing in for one until the panel has loaded the page.
private struct ArtifactThumbnail: View {
    let file: URL?
    let width: Double
    let height: Double

    var body: some View {
        Group {
            if let file, let image = NSImage(contentsOf: file) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width, height: height, alignment: .top)
                    .clipped()
            } else {
                let gap = width > 50 ? 3.0 : 2.0
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: gap), count: 3), spacing: gap) {
                    ForEach(0..<6, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 2).fill(ChatStyle.thumbnailTile)
                            .frame(height: (height - 2 * (gap + 2) - gap) / 2)
                    }
                }
                .padding(gap + 2)
            }
        }
        .frame(width: width, height: height)
        .background(ChatStyle.thumbnailFill)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(ChatStyle.cardBorder))
    }
}
