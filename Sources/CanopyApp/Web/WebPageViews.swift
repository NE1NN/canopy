import AppKit
import CanopyCore
import SwiftUI
import WebKit

/// A page's web view, with WebKit's error and Reload over it when the page failed to load. The web view belongs to the
/// page, so it keeps its state while the page moves or is out of view.
struct WebPageView: View {
    @Environment(AppModel.self) private var model
    let page: CanopyCore.WebPage

    var body: some View {
        if let controller = model.webViews.controller(for: page) {
            WebViewHost(webView: controller.webView) { model.webPageFocusChanged(page.id, $0) }
                .overlay {
                    if let error = controller.error {
                        ContentUnavailableView {
                            Label("Page Did Not Load", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(error)
                        } actions: {
                            Button("Reload", action: controller.reload)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Style.panelBackground)
                    }
                }
        }
    }
}

private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    var onFocusChange: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> WebViewContainer {
        WebViewContainer(webView: webView)
    }

    func updateNSView(_ container: WebViewContainer, context: Context) {
        container.adopt(webView)
        container.onFocusChange = onFocusChange
    }

    static func dismantleNSView(_ container: WebViewContainer, coordinator: ()) {
        container.dismantle()
    }
}

/// Holds a web view that may move to another container, as when its page moves between the panel and a tab.
final class WebViewContainer: NSView {
    private var webView: WKWebView
    var onFocusChange: (Bool) -> Void = { _ in }
    private var focusObservation: NSKeyValueObservation?

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        adopt(webView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    func adopt(_ webView: WKWebView) {
        if self.webView !== webView { release() }
        self.webView = webView
        guard webView.superview !== self else { return }
        webView.removeFromSuperview()
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)
    }

    func release() {
        if webView.superview === self { webView.removeFromSuperview() }
    }

    func dismantle() {
        focusObservation = nil
        release()
    }

    /// Tells the model while the keyboard is in the page, so ⌘W closes the panel's page rather than a terminal.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusObservation = window?.observe(\.firstResponder, options: [.initial, .new]) { [weak self] window, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let view = window.firstResponder as? NSView
                self.onFocusChange(view?.isDescendant(of: self.webView) ?? false)
            }
        }
    }
}

/// What sits above a page, in the panel and in a web tab: its title, Reload, Open in Browser, the move, and Close.
struct WebHeader: View {
    @Environment(AppModel.self) private var model
    let page: CanopyCore.WebPage
    let placement: WebPlacement
    let onMove: () -> Void
    let onClose: () -> Void

    var body: some View {
        let controller = model.webViews.controller(for: page)
        let isLoading = controller?.isLoading ?? false
        HStack(spacing: 2) {
            Group {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: "globe")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 16, height: 16)
            .padding(.trailing, 4)
            Text(isLoading ? (page.url.host() ?? page.displayTitle) : page.displayTitle)
                .font(Style.body.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(page.url.absoluteString)
            Spacer(minLength: 8)
            IconButton(title: "Reload", systemImage: "arrow.clockwise", shortcut: "⌘R") { controller?.reload() }
            IconButton(title: "Open in Browser", systemImage: "safari") {
                model.openInBrowser(controller?.webView.url ?? page.url)
            }
            IconButton(
                title: placement == .panel ? "Move to Tab" : "Move to Panel",
                systemImage: placement == .panel ? "menubar.rectangle" : "sidebar.right", action: onMove)
            IconButton(title: placement == .panel ? "Close Panel" : "Close Page", systemImage: "xmark", action: onClose)
        }
        .padding(.leading, placement == .panel ? 14 : 10)
        .padding(.trailing, placement == .panel ? Style.topBarInset : 5)
    }
}

/// A web tab's page under its header.
struct WebTabView: View {
    @Environment(AppModel.self) private var model
    let tab: TerminalTab
    let page: CanopyCore.WebPage
    let path: String

    var body: some View {
        VStack(spacing: 0) {
            WebHeader(
                page: page, placement: .tab,
                onMove: { model.terminals.moveTabToPanel(tab.id, inRow: path) },
                onClose: { model.terminals.closeTab(tab.id, inRow: path) }
            )
            .frame(height: Style.webTabHeaderHeight)
            .background(Style.chrome)
            .overlay(alignment: .bottom) {
                Rectangle().fill(.separator).frame(height: 1)
            }
            WebPageView(page: page)
        }
    }
}

/// The panel's header, level with the top bar in the title bar's row, which RootView draws over the window. Its empty
/// space moves the window like a title bar.
struct WebPanelHeader: View {
    @Environment(AppModel.self) private var model
    let page: CanopyCore.WebPage
    let path: String

    var body: some View {
        WebHeader(
            page: page, placement: .panel,
            onMove: { model.terminals.movePanelPageToTab(inRow: path) },
            onClose: { model.terminals.closePanel(inRow: path) }
        )
        .frame(height: Style.topBarHeight)
        .background {
            TitleBarArea()
                .background(Style.chrome)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(.separator).frame(height: 1)
        }
    }
}

/// The row's terminals, with its panel page on the right while the panel shows.
struct WebPanelSplit<Content: View>: View {
    @Environment(AppModel.self) private var model
    let path: String
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                content
                if let page = model.terminals.shownPanel(inRow: path) {
                    let width = model.webPanelWidth(available: geometry.size.width)
                    PanelDivider(width: width, side: .trailing) {
                        model.dragWebPanel(to: $0)
                    } onEnd: {
                        model.endWebPanelDrag(available: geometry.size.width)
                    }
                    VStack(spacing: 0) {
                        // Room for the panel's header, which RootView draws beside the top bar.
                        Color.clear.frame(height: Style.topBarHeight)
                        WebPageView(page: page)
                    }
                    .frame(width: width)
                    .background(Style.panelBackground)
                }
            }
        }
    }
}

/// A page's window of its own, such as Google's sign-in, in a sheet that closes when the page closes it.
struct WebPopUpSheet: View {
    @Environment(AppModel.self) private var model
    let popUp: WebPopUp

    var body: some View {
        VStack(spacing: 0) {
            WebViewHost(webView: popUp.webView)
                .frame(minWidth: 480, idealWidth: 500, minHeight: 560, idealHeight: 640)
            Divider()
            HStack {
                Text(popUp.webView.url?.host() ?? "")
                    .font(Style.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Cancel") { model.dismissPopUp(popUp.webView) }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .onDisappear { popUp.owner.popUpDismissed(popUp.webView) }
    }
}

struct WebPopUp: Identifiable {
    let id = UUID()
    let webView: WKWebView
    /// The page that asked for it.
    let owner: WebPageController
}
