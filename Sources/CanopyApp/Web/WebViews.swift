import AppKit
import CanopyCore
import Observation
import WebKit

/// Every page's web view, made the first time the page shows and kept until it closes, so moving a page between the
/// panel and a tab, or switching away and back, keeps its scroll position and state. WebKit names a type `WebPage` too,
/// so this file says `CanopyCore.WebPage` for Canopy's.
@MainActor
final class WebViews {
    private var controllers: [WebPageID: WebPageController] = [:]
    /// One configuration for every page, so they share the persistent website data, and a sign-in with them.
    private let configuration: WKWebViewConfiguration
    /// Where a page's web view went and what it is called now.
    var onNavigated: (WebPageID, URL?, String?) -> Void = { _, _, _ in }
    var openInBrowser: (URL) -> Void = { _ in }
    /// A page asked for a window of its own, such as Google's sign-in. Returns whether it shows.
    var presentPopUp: (WKWebView, WebPageController) -> Bool = { _, _ in false }
    /// Whether a page is still in a row, so a view drawn a moment after it closed never brings its web view back.
    var isOpen: (WebPageID) -> Bool = { _ in false }
    var dismissPopUp: (WKWebView) -> Void = { _ in }

    init() {
        configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        // Only a click opens a window, so a page cannot stack sheets over the window on its own.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let safari = Bundle(path: "/Applications/Safari.app")?.object(
            forInfoDictionaryKey: "CFBundleShortVersionString")
        configuration.applicationNameForUserAgent = SafariUserAgent.applicationName(safariVersion: safari as? String)
    }

    /// The page's controller, made and loaded on first use. Nil for a page that closed.
    func controller(for page: CanopyCore.WebPage) -> WebPageController? {
        if let controller = controllers[page.id] { return controller }
        guard isOpen(page.id) else { return nil }
        let controller = WebPageController(page: page, configuration: configuration, owner: self)
        controllers[page.id] = controller
        return controller
    }

    /// The controller of a page that has shown, without making one.
    func existing(_ id: WebPageID) -> WebPageController? {
        controllers[id]
    }

    func drop(_ id: WebPageID) {
        controllers.removeValue(forKey: id)?.close()
    }
}

/// One page's web view and what the header shows about it.
@MainActor
@Observable
final class WebPageController: NSObject, WKNavigationDelegate, WKUIDelegate {
    let pageID: WebPageID
    private let site: String
    @ObservationIgnored let webView: CanopyWebView
    private(set) var isLoading = false
    /// WebKit's description of why the page failed to load, until it loads again.
    private(set) var error: String?
    @ObservationIgnored private var restartedAfterCrash = false
    @ObservationIgnored private weak var owner: WebViews?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var popUps: [WKWebView] = []

    init(page: CanopyCore.WebPage, configuration: WKWebViewConfiguration, owner: WebViews) {
        pageID = page.id
        site = page.site
        self.owner = owner
        webView = CanopyWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.navigated(url: nil, title: webView.title) }
            },
            webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.navigated(url: webView.url, title: nil) }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.isLoading = webView.isLoading }
            },
        ]
        webView.load(URLRequest(url: page.url))
    }

    func reload() {
        error = nil
        if webView.url == nil, let url = webView.backForwardList.currentItem?.url {
            webView.load(URLRequest(url: url))
        } else {
            webView.reload()
        }
    }

    fileprivate func close() {
        observations = []
        for popUp in popUps {
            owner?.dismissPopUp(popUp)
        }
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
    }

    private func navigated(url: URL?, title: String?) {
        // Pages that are not web addresses, such as about:blank, never replace the page's own.
        let url = url.flatMap { WebAddress.isWeb($0) ? $0 : nil }
        let title = title.flatMap { $0.isEmpty ? nil : $0 }
        guard url != nil || title != nil else { return }
        owner?.onNavigated(pageID, url, title)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async
        -> WKNavigationActionPolicy
    {
        // Frames inside the page, such as an artifact's sandbox, are the page's own business.
        guard navigationAction.targetFrame?.isMainFrame ?? true, let url = navigationAction.request.url else {
            return .allow
        }
        let isLinkClick = navigationAction.navigationType == .linkActivated
        let site = webView === self.webView ? site : WebNavigation.site(of: url)
        switch WebNavigation.decide(url, site: site, isLinkClick: isLinkClick) {
        case .allow: return .allow
        case .openInBrowser:
            if isInFront { owner?.openInBrowser(url) }
            return .cancel
        case .refuse: return .cancel
        }
    }

    /// Downloads are not something a page here can do.
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async
        -> WKNavigationResponsePolicy
    {
        navigationResponse.canShowMIMEType ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if webView === self.webView { error = nil }
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error
    ) {
        failed(webView, error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        failed(webView, error)
    }

    private func failed(_ webView: WKWebView, _ error: any Error) {
        let error = error as NSError
        // A navigation stopped by a newer one, or refused above, is not a failure to show.
        let ignored =
            (error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled)
            || (error.domain == WKErrorDomain && error.code == 102)
        guard webView === self.webView, !ignored else { return }
        self.error = error.localizedDescription
    }

    // MARK: WKUIDelegate

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let url = navigationAction.request.url
        let isLinkClick = navigationAction.navigationType == .linkActivated
        switch WebNavigation.decideNewWindow(url, site: site, isLinkClick: isLinkClick) {
        case .popUp:
            guard isInFront else { return nil }
            let popUp = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 600), configuration: configuration)
            popUp.navigationDelegate = self
            popUp.uiDelegate = self
            guard owner?.presentPopUp(popUp, self) == true else { return nil }
            popUps.append(popUp)
            return popUp
        case .loadInPage:
            if let url { self.webView.load(URLRequest(url: url)) }
            return nil
        case .openInBrowser:
            if let url, isInFront { owner?.openInBrowser(url) }
            return nil
        case .refuse:
            return nil
        }
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let index = popUps.firstIndex(where: { $0 === webView }) else { return }
        popUps.remove(at: index)
        owner?.dismissPopUp(webView)
    }

    /// The author closed the pop-up's sheet before the page did.
    func popUpDismissed(_ popUp: WKWebView) {
        popUps.removeAll { $0 === popUp }
    }

    /// Reloads once. A page whose web process ends again shows the error, rather than reloading forever.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        if restartedAfterCrash {
            error = "The page stopped working. Reload to try again."
        } else {
            restartedAfterCrash = true
            reload()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === self.webView { restartedAfterCrash = false }
    }

    /// Only a page the author can see opens the browser or a pop-up, so one in a background row cannot.
    private var isInFront: Bool {
        webView.window != nil && NSApp.isActive
    }
}

/// A page's web view, with the keys a browser gives it while it has focus.
final class CanopyWebView: WKWebView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let isFocused = window?.firstResponder.flatMap { ($0 as? NSView)?.isDescendant(of: self) } ?? false
        guard isFocused, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "r": reload()
        case "[": goBack()
        case "]": goForward()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}
