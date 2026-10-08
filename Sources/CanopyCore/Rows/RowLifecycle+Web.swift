import Foundation

/// What `canopy web` does, on the main actor where pages live.
extension RowLifecycle {
    /// Opens the page by the rules of `TerminalStore.openPage`. The row's selection in the sidebar never changes.
    public func openPage(_ url: URL, for context: PaneContext, placement: WebPlacement?) -> WebOpenResult {
        let opened = terminals.openPage(url, for: context, placement: placement)
        return WebOpenResult(page: opened.page.id.description, placement: opened.placement, row: context.rowName)
    }

    /// Pages in one row, or in every row when `rowPath` is nil.
    public func pageInfo(rowPath: String?, repoNames: [String: String]) -> [WebPageInfo] {
        let paths = rowPath.map { [$0] } ?? terminals.rowPaths.sorted()
        return paths.flatMap { path in
            terminals.pages(inRow: path).map { page, placement in
                let context = page.context
                var plugin: String?
                if case .plugin(let id, _) = context.owner { plugin = id }
                return WebPageInfo(
                    page: page.id.description, url: page.url.absoluteString, title: page.displayTitle,
                    placement: placement, repo: context.repoPath.flatMap { repoNames[$0] } ?? context.repoName,
                    plugin: plugin, row: context.rowName, rowPath: path)
            }
        }
    }

    public func closePage(_ id: String) throws {
        guard let pageID = WebPageID(id), terminals.closePage(pageID) else { throw WorkspaceError.pageNotFound(id) }
    }
}
