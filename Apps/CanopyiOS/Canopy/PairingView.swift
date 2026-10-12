import CanopyPhone
import SwiftUI
import UIKit

/// Scans the code `canopy phone pair` shows on the Mac, or takes its link pasted.
struct PairingView: View {
    @Environment(PhoneApp.self) private var app
    @State private var camera = CameraAccess.current

    private var model: PairingModel { app.pairing }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 10) {
                    AppGlyph(size: 56)
                    Text("Pair with your Mac")
                        .font(.title2.weight(.bold))
                    Text("On the Mac, run canopy phone pair, then scan the code it shows.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 24)
                if let notice = model.notice {
                    Banner(problem: PhoneProblem(title: notice), tint: Theme.yellow)
                        .padding(.horizontal, -16)
                }
                scanner
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 20, style: .continuous))
                    .overlay {
                        if model.isPairing {
                            ZStack {
                                Color.black.opacity(0.45)
                                VStack(spacing: 10) {
                                    ProgressView().tint(.white)
                                    Text("Pairing").foregroundStyle(.white).font(.subheadline.weight(.semibold))
                                }
                            }
                            .clipShape(.rect(cornerRadius: 20, style: .continuous))
                        }
                    }
                if let problem = model.problem {
                    VStack(spacing: 4) {
                        Text(problem.title).font(.subheadline.weight(.semibold))
                        if !problem.detail.isEmpty {
                            Text(problem.detail).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.red)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("pairing-problem")
                }
                Button {
                    Task { await model.pair(text: UIPasteboard.general.string ?? "") }
                } label: {
                    Label("Paste link", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(ChipStyle(kind: .tinted))
                .disabled(model.isPairing)
                .accessibilityIdentifier("paste-link")
                Text("canopy phone pair --json on the Mac prints the link to copy.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .background(Theme.background)
        .task { camera = await CameraAccess.request() }
    }

    @ViewBuilder
    private var scanner: some View {
        switch camera {
        case .allowed:
            QRScanner { code in
                guard let url = URL(string: code) else { return }
                Task { await model.pair(url) }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.9), lineWidth: 3)
                    .padding(48)
            }
        case .denied:
            placeholder(
                "Canopy can't use the camera", detail: "Allow it in Settings, or paste the link instead.",
                action: (
                    "Open Settings", { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                ))
        case .unavailable:
            placeholder("No camera here", detail: "Paste the link instead.", action: nil)
        case .unknown:
            Theme.fill
        }
    }

    private func placeholder(_ title: String, detail: String, action: (String, () -> Void)?) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let action {
                Button(action.0, action: action.1).font(.footnote.weight(.semibold))
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.card)
    }
}
