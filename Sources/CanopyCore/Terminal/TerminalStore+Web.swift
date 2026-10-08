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
        if let panel = panelsByRow[path], panel.page.url == url {
            setPanelHidden(false, inRow: path)
            return OpenedPage(page: panel.page, placement: .panel, isNew: false)
        }
        if let tab = tabs(inRow: path).first(where: { $0.page?.url == url }), let page = tab.page {
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
