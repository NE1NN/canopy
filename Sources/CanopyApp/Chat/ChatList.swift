import AppKit
import CanopyCore
import SwiftUI

/// A chat's conversation in an `NSTableView` of SwiftUI rows, so only rows near the viewport are laid out and a
/// conversation of thousands of messages scrolls as one of twenty does. It keeps to the newest row while the author
/// is at the bottom, and asks for older history as they near the top.
struct ChatList: NSViewRepresentable {
    let chat: ChatSession
    let rows: [ChatRow]
    let actions: ChatActions
    /// Whether the newest row is in view, for the Jump to latest button.
    @Binding var isAtBottom: Bool
    /// Changes when the author asks to see the newest row.
    let scrollToBottomRequest: Int

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(chat: chat, actions: actions, isAtBottom: $isAtBottom)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.headerView = nil
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.intercellSpacing = .zero
        table.gridStyleMask = []
        table.style = .plain
        table.focusRingType = .none
        let column = NSTableColumn(identifier: .init("row"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = context.coordinator
        table.delegate = context.coordinator

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.contentInsets = NSEdgeInsets(top: ChatStyle.topPadding, left: 0, bottom: 0, right: 0)
        scroll.automaticallyAdjustsContentInsets = false
        context.coordinator.attach(table: table, scroll: scroll)
        context.coordinator.update(rows, scrollRequest: scrollToBottomRequest)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.actions = actions
        context.coordinator.update(rows, scrollRequest: scrollToBottomRequest)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let chat: ChatSession
        var actions: ChatActions
        private var isAtBottom: Binding<Bool>
        private var rows: [ChatRow] = []
        private var keys: [String] = []
        private weak var table: NSTableView?
        private weak var scroll: NSScrollView?
        private var scrollRequest = 0
        private var followsBottom = true
        private var observer: NSObjectProtocol?
        /// Row heights by key, at `measuredWidth`. A row is measured once per width and change.
        private var heights: [String: Double] = [:]
        private var measuredWidth = 0.0
        private lazy var sizer = NSHostingController(rootView: ChatRowView(row: .empty, chat: chat, actions: actions))

        init(chat: ChatSession, actions: ChatActions, isAtBottom: Binding<Bool>) {
            self.chat = chat
            self.actions = actions
            self.isAtBottom = isAtBottom
        }

        func attach(table: NSTableView, scroll: NSScrollView) {
            self.table = table
            self.scroll = scroll
            scroll.contentView.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.scrolled() }
            }
        }

        func detach() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }

        func update(_ newRows: [ChatRow], scrollRequest request: Int) {
            guard let table else { return }
            let newKeys = newRows.map(\.key)
            let forced = request != scrollRequest
            scrollRequest = request
            guard newKeys != keys else {
                if forced { scrollToBottom() }
                return
            }
            let oldIDs = rows.map(\.id)
            let newIDs = newRows.map(\.id)
            let prepended = Self.prepended(old: oldIDs, new: newIDs)
            let heightBefore = table.bounds.height
            let originBefore = scroll?.contentView.bounds.origin.y ?? 0

            let live = Set(newKeys)
            heights = heights.filter { live.contains($0.key) }
            if oldIDs == newIDs {
                let changed = IndexSet(newKeys.indices.filter { newKeys[$0] != keys[$0] })
                rows = newRows
                keys = newKeys
                table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
                table.noteHeightOfRows(withIndexesChanged: changed)
            } else if rows.isEmpty || oldIDs.isEmpty {
                rows = newRows
                keys = newKeys
                table.reloadData()
            } else {
                let difference = newIDs.difference(from: oldIDs)
                let oldKeys = Dictionary(zip(oldIDs, keys), uniquingKeysWith: { first, _ in first })
                rows = newRows
                keys = newKeys
                table.beginUpdates()
                for change in difference {
                    if case .remove(let offset, _, _) = change {
                        table.removeRows(at: IndexSet(integer: offset), withAnimation: [])
                    }
                }
                for change in difference {
                    if case .insert(let offset, _, _) = change {
                        table.insertRows(at: IndexSet(integer: offset), withAnimation: [])
                    }
                }
                table.endUpdates()
                let changed = IndexSet(
                    newIDs.indices.filter { index in
                        oldKeys[newIDs[index]].map { old in old != newKeys[index] } ?? false
                    })
                if !changed.isEmpty {
                    table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
                    table.noteHeightOfRows(withIndexesChanged: changed)
                }
            }

            if prepended > 0, !followsBottom, let scroll {
                // Older history went in above: keep what the author was reading where it was.
                table.layoutSubtreeIfNeeded()
                let grown = table.bounds.height - heightBefore
                scroll.contentView.scroll(to: NSPoint(x: 0, y: originBefore + grown))
                scroll.reflectScrolledClipView(scroll.contentView)
            } else if followsBottom || forced {
                scrollToBottom()
            }
            // A first page that fits on screen never scrolls, so older history would be out of reach.
            if chat.hasOlder, let scroll, table.bounds.height < scroll.contentView.bounds.height {
                chat.loadOlder()
            }
        }

        /// How many rows came in ahead of the old first one.
        static func prepended(old: [String], new: [String]) -> Int {
            guard let first = old.first, let index = new.firstIndex(of: first) else { return 0 }
            return index
        }

        private func scrollToBottom() {
            guard let table, let scroll, !rows.isEmpty else { return }
            followsBottom = true
            table.layoutSubtreeIfNeeded()
            let bottom = max(-scroll.contentInsets.top, table.bounds.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
            scroll.reflectScrolledClipView(scroll.contentView)
            setAtBottom(true)
        }

        private func scrolled() {
            guard let table, let scroll else { return }
            let visible = scroll.contentView.bounds
            let atBottom = visible.maxY >= table.bounds.height - 40
            followsBottom = atBottom
            setAtBottom(atBottom)
            if visible.minY < 300, chat.hasOlder {
                chat.loadOlder()
            }
        }

        private func setAtBottom(_ value: Bool) {
            if isAtBottom.wrappedValue != value { isAtBottom.wrappedValue = value }
        }

        // MARK: Table

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let view = ChatRowView(row: rows[row], chat: chat, actions: actions)
            let identifier = NSUserInterfaceItemIdentifier("chat-row")
            if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSHostingView<ChatRowView> {
                reused.rootView = view
                return reused
            }
            let hosting = NSHostingView(rootView: view)
            hosting.identifier = identifier
            hosting.sizingOptions = [.intrinsicContentSize]
            return hosting
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            false
        }

        /// Measured at the column's width, since a wrapped message is taller than its one-line ideal.
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            // The drawn column, which a scroll bar that takes room makes narrower than the table.
            let width = tableView.rect(ofColumn: 0).width
            if width != measuredWidth {
                measuredWidth = width
                heights = [:]
            }
            let key = keys[row]
            if let height = heights[key] { return height }
            // Laid out again before measuring: until then a reused controller answers with its last row's size.
            sizer.rootView = ChatRowView(row: rows[row], chat: chat, actions: actions)
            sizer.view.layoutSubtreeIfNeeded()
            let height = max(
                1, ceil(sizer.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height))
            heights[key] = height
            return height
        }

        /// A new width wraps every row differently.
        func tableViewColumnDidResize(_ notification: Notification) {
            guard let table, !rows.isEmpty else { return }
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
            if followsBottom { scrollToBottom() }
        }
    }
}
