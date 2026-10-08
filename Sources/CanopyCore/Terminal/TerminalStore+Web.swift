import Foundation

/// Web pages in rows: one in each row's panel, and any number in tabs of their own.
extension TerminalStore {
    /// The number the next page gets, saved so IDs keep counting up across launches.
    public var nextWebPageNumber: Int { nextWebPage }

    public func continueWebNumbering(from number: Int) {
        nextWebPage = max(nextWebPage, number)
    }

    public func panel(inRow path: String) -> WebPanel? {
        panelsByRow[path]
    }

    /// The row's panel page while the panel shows.
    public func shownPanel(inRow path: String) -> WebPage? {
        panelsByRow[path].flatMap { $0.isHidden ? nil : $0.page }
    }

    /// Shows `url` in the row. A page the row already shows is shown where it is. Otherwise it opens in the panel,
    /// replacing the panel's page, or in a new tab after the selected one, by `placement` or else where the author
    /// last moved a page. Either way the row's panel shows, or the page's tab is selected.
    @discardableResult
    public func openPage(_ url: URL, for context: PaneContext, placement: WebPlacement? = nil) -> OpenedPage {
        let path = context.rowPath
        if let panel = panelsByRow[path], panel.page.shows(url) {
            setPanelHidden(false, inRow: path)
            return OpenedPage(page: panel.page, placement: .panel, isNew: false)
        }
        if let tab = tabs(inRow: path).first(where: { $0.page?.shows(url) == true }), let page = tab.page {
            selectTab(tab.id, inRow: path)
            return OpenedPage(page: page, placement: .tab, isNew: false)
        }
        let page = WebPage(id: WebPageID(nextWebPage), url: url, title: "", context: context)
        nextWebPage += 1
        let placement = placement ?? webPlacement
        switch placement {
        case .panel:
            let replaced = panelsByRow[path]?.page
            panelsByRow[path] = WebPanel(page: page, isHidden: false)
            replaced.map(retire)
        case .tab:
            insertTab(for: page, inRow: path)
        }
        record(ActivityType.webOpened, page, ["placement": .string(placement.rawValue)])
        onChange()
        return OpenedPage(page: page, placement: placement, isNew: true)
    }

    /// The panel's page, into a new tab after the selected one. New pages open in tabs from now on.
    public func movePanelPageToTab(inRow path: String) {
        guard let page = panelsByRow.removeValue(forKey: path)?.page else { return }
        insertTab(for: page, inRow: path)
        webPlacement = .tab
        onChange()
    }

    /// A web tab's page, into the row's panel. A page the panel held already takes the tab's place, so nothing is lost.
    /// New pages open in the panel from now on.
    public func moveTabToPanel(_ id: TabID, inRow path: String) {
        var tabs = tabs(inRow: path)
        guard let index = tabs.firstIndex(where: { $0.id == id }), let page = tabs[index].page else { return }
        let wasSelected = selectedTab(inRow: path)?.id == id
        tabs.remove(at: index)
        tabsByRow[path] = tabs.isEmpty ? nil : tabs
        if tabs.isEmpty {
            selectedTabByRow[path] = nil
        } else if wasSelected {
            selectedTabByRow[path] = tabs[min(index, tabs.count - 1)].id
        }
        let selected = selectedTabByRow[path]
        if let replaced = panelsByRow[path]?.page {
            insertTab(for: replaced, inRow: path, at: index)
            if let selected { selectedTabByRow[path] = selected }
        }
        panelsByRow[path] = WebPanel(page: page, isHidden: false)
        webPlacement = .panel
        markSeenOnScreen()
        onChange()
    }

    /// The panel's close button: the page closes, and the panel with it.
    public func closePanel(inRow path: String) {
        guard let page = panelsByRow.removeValue(forKey: path)?.page else { return }
        retire(page)
        onChange()
    }

    /// Closes a page wherever it is. Returns false when no row has it.
    @discardableResult
    public func closePage(_ id: WebPageID) -> Bool {
        guard let found = page(id) else { return false }
        switch found.placement {
        case .panel: closePanel(inRow: found.path)
        case .tab:
            if let tab = tabs(inRow: found.path).first(where: { $0.page?.id == id }) {
                closeTab(tab.id, inRow: found.path)
            }
        }
        return true
    }

    /// The page with this ID, the row it is in, and where.
    public func page(_ id: WebPageID) -> (page: WebPage, path: String, placement: WebPlacement)? {
        for path in rowPaths {
            if let found = pages(inRow: path).first(where: { $0.page.id == id }) {
                return (found.page, path, found.placement)
            }
        }
        return nil
    }

    /// The row's panel page, then its web tabs in tab bar order.
    public func pages(inRow path: String) -> [(page: WebPage, placement: WebPlacement)] {
        let panel = panelsByRow[path].map { [($0.page, WebPlacement.panel)] } ?? []
        return panel + tabs(inRow: path).compactMap { tab in tab.page.map { ($0, .tab) } }
    }

    /// Where the page's web view went and what it is called now.
    public func pageNavigated(_ id: WebPageID, url: URL?, title: String?) {
        guard let page = page(id)?.page else { return }
        var changed = false
        if let url, page.url != url {
            page.url = url
            changed = true
        }
        if let title, page.title != title {
            page.title = title
            changed = true
        }
        if changed { onChange() }
    }

    /// Opens an artifact link ⌘-clicked in a pane in the pane's row. Returns where the link goes.
    @discardableResult
    public func followLink(_ link: String, from pane: Pane) -> TerminalLink {
        let route = TerminalLink(link)
        if case .artifact(let url) = route {
            openPage(url, for: pane.context)
        }
        return route
    }

    public func setPanelHidden(_ hidden: Bool, inRow path: String) {
        guard panelsByRow[path] != nil, panelsByRow[path]?.isHidden != hidden else { return }
        panelsByRow[path]?.isHidden = hidden
        onChange()
    }

    /// A new web tab after the row's selected tab, selected.
    func insertTab(for page: WebPage, inRow path: String, at index: Int? = nil) {
        var tabs = tabs(inRow: path)
        let selected = selectedTab(inRow: path).flatMap { selected in tabs.firstIndex { $0.id == selected.id } }
        let tab = TerminalTab(id: TabID(nextTab), page: page)
        nextTab += 1
        tabs.insert(tab, at: min(index ?? selected.map { $0 + 1 } ?? tabs.count, tabs.count))
        tabsByRow[path] = tabs
        selectedTabByRow[path] = tab.id
        markSeenOnScreen()
    }

    /// Logs a page that closed and lets the app drop its web view.
    func retire(_ page: WebPage) {
        record(ActivityType.webClosed, page)
        onPageClosed(page.id)
    }

    func record(_ type: String, _ page: WebPage, _ data: [String: JSONValue] = [:]) {
        var data = data.merging(["url": .string(page.url.absoluteString), "page": .string(page.id.description)]) {
            value, _ in value
        }
        if case .plugin(let plugin, let item) = page.context.owner {
            data["plugin"] = .string(plugin)
            data["item"] = .string(item)
        }
        activity.record(
            type, repo: page.context.repoName, row: page.context.rowName, path: page.context.rowPath, data: data)
    }
}
