import AppKit
import CanopyCore
import SwiftUI

/// A chat's conversation in an `NSTableView` of SwiftUI rows, so only rows near the viewport are laid out and a
/// conversation of thousands of messages scrolls as one of twenty does. It keeps to the newest row while the author
/// is at the bottom, and asks for older history as they near the top.
struct ChatList: NSViewRepresentable {
    let chat: ChatSession
    /// The conversation's rows. What is pending after them, such as the text Claude is writing, the list follows
    /// itself.
    let conversation: [ChatRow]
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
        context.coordinator.show(conversation: conversation, scrollRequest: scrollToBottomRequest)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.actions = actions
        context.coordinator.show(conversation: conversation, scrollRequest: scrollToBottomRequest)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let chat: ChatSession
        var actions: ChatActions
        private var isAtBottom: Binding<Bool>
        private var rows: [ChatRow] = []
        private var keys: [String] = []
        private var ids: [String] = []
        private weak var table: NSTableView?
        private weak var scroll: NSScrollView?
        private var scrollRequest = 0
        private var followsBottom = true
        private var updating = false
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
            table = nil
        }

        /// One half of the rows, with their keys and IDs worked out once.
        private struct Half {
            var rows: [ChatRow] = []
            var keys: [String] = []
            var ids: [String] = []

            init(_ rows: [ChatRow] = []) {
                self.rows = rows
                keys = rows.map { $0.key }
                ids = rows.map { $0.id }
            }
        }

        private var conversation = Half()
        private var pending = Half()
        private var stalePending = true
        private var followScheduled = false
        /// A conversation shown while what is pending was still to be read, applied with it.
        private var deferred: (unchanged: Int, request: Int)?
        /// The author scrolled while the table was between updates, so where they are is checked once it is not.
        private var scrollSkipped = false
        /// Where the author's last scroll left the view, to tell scrolling up from scrolling down.
        private var lastOrigin: CGFloat = 0

        /// Shows the conversation SwiftUI read for this update. It changes only when items do, so it is shown inside
        /// SwiftUI's update, as one batch with the rest of the chat.
        func show(conversation newRows: [ChatRow], scrollRequest request: Int) {
            let half = Half(newRows)
            var unchanged = conversation.rows.count
            if half.keys != conversation.keys || half.ids != conversation.ids {
                conversation = half
                unchanged = 0
            }
            // Read later, outside SwiftUI's update, which would otherwise follow the streaming text too.
            if stalePending {
                pendingChanged()
                // What is pending changed with the conversation, as when a reply settles into an item, so both are
                // shown together then rather than the reply twice for a frame now.
                if !rows.isEmpty {
                    deferred = (min(deferred?.unchanged ?? unchanged, unchanged), request)
                    return
                }
            }
            showRows(unchanged: unchanged, scrollRequest: request)
        }

        /// The text Claude is writing and the rest of what is pending are followed here rather than read in a
        /// SwiftUI body, so each redraw of the reply updates the table without SwiftUI laying out the chat again.
        private func followPending() {
            guard stalePending else { return }
            stalePending = false
            pending = Half(
                withObservationTracking {
                    ChatRows.pending(for: chat)
                } onChange: { [weak self] in
                    MainActor.assumeIsolated { self?.pendingChanged() }
                })
        }

        private func showRows(unchanged: Int, scrollRequest request: Int) {
            guard table != nil else { return }
            if conversation.rows.isEmpty, pending.rows.isEmpty {
                let empty = Half([.empty])
                update(empty.rows, keys: empty.keys, ids: empty.ids, scrollRequest: request)
            } else {
                update(
                    conversation.rows + pending.rows, keys: conversation.keys + pending.keys,
                    ids: conversation.ids + pending.ids,
                    unchanged: rows.count < unchanged || rows == [.empty] ? 0 : unchanged, scrollRequest: request)
            }
        }

        /// Observation calls before a change lands, on the main actor that owns the chat, so the rows are read on a
        /// later turn of the run loop, which also gathers a burst of changes into one update.
        private func pendingChanged() {
            stalePending = true
            guard !followScheduled else { return }
            followScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.followScheduled = false
                self.recheckScroll()
                let old = self.pending
                self.followPending()
                if let deferred = self.deferred {
                    self.deferred = nil
                    self.showRows(unchanged: deferred.unchanged, scrollRequest: deferred.request)
                } else if !self.showPendingInPlace(old: old) {
                    self.showRows(unchanged: self.conversation.rows.count, scrollRequest: self.scrollRequest)
                }
            }
        }

        /// Redraws the pending rows that changed when none came or went, which is each redraw of the text Claude
        /// is writing, without going over the conversation's rows. Returns false when rows came or went.
        private func showPendingInPlace(old: Half) -> Bool {
            let start = conversation.rows.count
            guard table != nil, old.ids == pending.ids, rows.count == start + old.rows.count, !pending.rows.isEmpty
            else { return false }
            let changed = IndexSet(pending.keys.indices.filter { pending.keys[$0] != old.keys[$0] }.map { $0 + start })
            guard !changed.isEmpty else { return true }
            for index in changed {
                rows[index] = pending.rows[index - start]
                keys[index] = pending.keys[index - start]
            }
            updating = true
            defer { finishUpdating() }
            if refresh(changed, old: { (old.rows[$0 - start], old.keys[$0 - start]) }), followsBottom {
                scrollToBottom()
            }
            return true
        }

        /// Shows `newRows`, of which the first `unchanged` are known to be as they were, so a long conversation is
        /// not compared row by row on every redraw of the text Claude is writing.
        private func update(
            _ newRows: [ChatRow], keys newKeys: [String], ids newIDs: [String], unchanged: Int = 0,
            scrollRequest request: Int
        ) {
            guard let table else { return }
            updating = true
            defer { finishUpdating() }
            let forced = request != scrollRequest
            scrollRequest = request
            guard newKeys.count != keys.count || newKeys[unchanged...] != keys[unchanged...] else {
                if forced { scrollToBottom() }
                return
            }
            let oldIDs = ids
            let sameIDs = newIDs.count == oldIDs.count && newIDs[unchanged...] == oldIDs[unchanged...]
            let prepended = Self.prepended(old: oldIDs, new: newIDs)
            let heightBefore = table.bounds.height
            let originBefore = scroll?.contentView.bounds.origin.y ?? 0

            let moved: Bool
            if sameIDs {
                let changed = IndexSet((unchanged..<newKeys.count).filter { newKeys[$0] != keys[$0] })
                let oldRows = rows
                let oldKeys = keys
                rows = newRows
                keys = newKeys
                moved = refresh(changed) { (oldRows[$0], oldKeys[$0]) }
            } else if rows.isEmpty || oldIDs.isEmpty {
                heights = [:]
                rows = newRows
                keys = newKeys
                ids = newIDs
                table.reloadData()
                moved = true
            } else {
                let difference = newIDs.difference(from: oldIDs)
                let oldKeys = Dictionary(zip(oldIDs, keys), uniquingKeysWith: { first, _ in first })
                let oldRows = Dictionary(zip(oldIDs, rows), uniquingKeysWith: { first, _ in first })
                rows = newRows
                keys = newKeys
                ids = newIDs
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
                _ = refresh(changed) { index in
                    oldRows[newIDs[index]].flatMap { row in oldKeys[newIDs[index]].map { (row, $0) } }
                }
                let live = Set(newKeys)
                heights = heights.filter { live.contains($0.key) }
                moved = true
            }

            if prepended > 0, !followsBottom, let scroll {
                // Older history went in above: keep what the author was reading where it was.
                table.layoutSubtreeIfNeeded()
                let grown = table.bounds.height - heightBefore
                scroll.contentView.scroll(to: NSPoint(x: 0, y: originBefore + grown))
                scroll.reflectScrolledClipView(scroll.contentView)
            } else if (followsBottom && moved) || forced {
                scrollToBottom()
            }
            // A first page that fits on screen never scrolls, so older history would be out of reach.
            if chat.hasOlder, let scroll, table.bounds.height < scroll.contentView.bounds.height {
                chat.loadOlder()
            }
        }

        /// Redraws rows whose content changed, and says whether any row moved or changed size. The text Claude is
        /// writing changes in place; the rest are made again.
        private func refresh(_ changed: IndexSet, old: (Int) -> (row: ChatRow, key: String)?) -> Bool {
            guard let table, !changed.isEmpty else { return false }
            var reload = IndexSet()
            var resized = IndexSet()
            let width = table.rect(ofColumn: 0).width
            for index in changed {
                let previous = old(index)
                let before = previous.flatMap { heights.removeValue(forKey: $0.key) }
                if let block = rows[index].growingText, previous?.row.growingText != nil,
                    let view = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? StreamingTextView
                {
                    view.show(block)
                    // Measured by the view's own layout, which its drawing reuses, rather than laid out twice.
                    guard width == measuredWidth else {
                        resized.insert(index)
                        continue
                    }
                    let height = view.rowHeight(width: width)
                    heights[keys[index]] = height
                    if height != before { resized.insert(index) }
                } else {
                    reload.insert(index)
                    resized.insert(index)
                }
            }
            if !reload.isEmpty {
                table.reloadData(forRowIndexes: reload, columnIndexes: IndexSet(integer: 0))
            }
            guard !resized.isEmpty else { return false }
            // A view-based table animates height changes unless told not to, which would run all through a reply.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                table.noteHeightOfRows(withIndexesChanged: resized)
            }
            return true
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

        private func finishUpdating() {
            updating = false
            lastOrigin = scroll?.contentView.bounds.origin.y ?? 0
            recheckScroll()
        }

        private func recheckScroll() {
            guard scrollSkipped, !updating, !followScheduled else { return }
            scrollSkipped = false
            scrolled()
        }

        private func scrolled() {
            // Not the author scrolling: rows going in move the clip view before the update scrolls where it means
            // to, and until a pending update lands the table still shows the rows from before it. Where the author
            // is gets checked again once the table is settled.
            guard !updating, !followScheduled else {
                scrollSkipped = true
                return
            }
            guard let table, let scroll else { return }
            let visible = scroll.contentView.bounds
            let atBottom = visible.maxY >= table.bounds.height - 40
            // Any scroll up stops following, or a slow one would be pulled back down by the next line Claude writes.
            // Settling back from past the bottom is not one.
            let movedUp = visible.origin.y < lastOrigin - 0.5 && visible.maxY < table.bounds.height - 0.5
            lastOrigin = visible.origin.y
            followsBottom = atBottom && !movedUp
            setAtBottom(followsBottom)
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
            if let block = rows[row].growingText {
                let view =
                    tableView.makeView(withIdentifier: StreamingTextView.identifier, owner: nil) as? StreamingTextView
                    ?? StreamingTextView()
                view.openLink = actions.openLink
                view.show(block)
                return view
            }
            let view = ChatRowView(row: rows[row], chat: chat, actions: actions)
            let identifier = NSUserInterfaceItemIdentifier("chat-row")
            if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSHostingView<ChatRowView> {
                reused.rootView = view
                return reused
            }
            let hosting = NSHostingView(rootView: view)
            hosting.identifier = identifier
            // Rows ignore the window's safe area, which would otherwise lay each one out again whenever the table
            // grows by a line as Claude writes.
            hosting.safeAreaRegions = []
            hosting.sizingOptions = [.intrinsicContentSize]
            return hosting
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            tableView.makeView(withIdentifier: ChatTableRowView.identifier, owner: nil) as? ChatTableRowView
                ?? ChatTableRowView()
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
            if let block = rows[row].growingText {
                let height = StreamingTextView.height(of: block, width: width)
                heights[key] = height
                return height
            }
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

/// A row that draws nothing of its own, so a row growing as Claude writes does not repaint an empty backing store
/// the size of the row each time.
private final class ChatTableRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("chat-row-view")

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
}
