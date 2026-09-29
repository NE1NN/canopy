import CanopyCore
import Foundation

extension TicketsPlugin {
    /// Starts watching the plugin's rows, selection, and window, and the loop that refreshes from them.
    func startRefreshing(_ context: PluginContext) {
        let generation = self.generation
        schedule = RefreshSchedule()
        for id in malformed { schedule.exclude(id) }
        watch = RefreshSchedule.Watch(isVisible: false, hasRows: false, selected: nil)
        wasFrontmost = false
        handledState = nil
        isLoopAsleep = false
        tasks.append(
            Task {
                for await state in await context.states() {
                    guard !Task.isCancelled else { return }
                    self.stateChanged(state, generation: generation)
                }
            })
        tasks.append(Task { await self.runLoop(context, generation: generation) })
    }

    /// Nudges the selected ticket when it is picked or the window comes to the front, forgets tickets whose rows went,
    /// and wakes the loop.
    func stateChanged(_ state: PluginState, generation: Int) {
        guard generation == self.generation else { return }
        handledState = state
        let selected = state.selectedRow?.item
        if let selected, selected != watch.selected || (state.viewing.isFrontmost && !wasFrontmost) {
            schedule.nudge(selected)
        }
        let rows = Set(state.rows.map(\.item))
        for ticket in watchedRows.subtracting(rows) where ticket != selected {
            schedule.forget(ticket)
        }
        watchedRows = rows
        wasFrontmost = state.viewing.isFrontmost
        watch = RefreshSchedule.Watch(
            isVisible: state.viewing.isWindowVisible, hasRows: !state.rows.isEmpty, selected: selected)
        // The loop wakes to look at what changed, so it is not idle until it sleeps again.
        if let sleeper, !sleeper.isCancelled {
            isLoopAsleep = false
            sleeper.cancel()
        }
    }

    /// Shows each row's saved ticket at once, then runs what the schedule says is due, sleeping between.
    func runLoop(_ context: PluginContext, generation: Int) async {
        await loadSavedTickets(context)
        while !Task.isCancelled, generation == self.generation {
            let due = schedule.due(at: clock.now, watch)
            for job in due {
                await run(job, generation: generation)
            }
            guard !Task.isCancelled, generation == self.generation else { return }
            if due.isEmpty {
                let deadline = schedule.nextDue(after: clock.now, watch) ?? clock.now + .seconds(3600)
                await sleep(until: deadline)
            }
        }
    }

    /// Sleeps on the clock until `deadline`, or until a change in what the plugin watches wakes it.
    private func sleep(until deadline: ContinuousClock.Instant) async {
        let clock = self.clock
        let sleeping = Task { await clock.sleep(until: deadline) }
        sleeper = sleeping
        let generation = self.generation
        isLoopAsleep = true
        await sleeping.value
        if generation == self.generation { isLoopAsleep = false }
    }

    private func run(_ job: RefreshSchedule.Job, generation: Int) async {
        schedule.started(job, at: clock.now)
        var succeeded = true
        do {
            switch job {
            case .rows: try await refreshRows()
            case .ticket(let id): try await fetchTicket(id)
            }
        } catch let error as TicketError {
            succeeded = !error.backsOff
        } catch {
            succeeded = false
        }
        guard generation == self.generation else { return }
        schedule.finished(job, at: clock.now, succeeded: succeeded)
    }

    /// Asks for every row's ticket at once, for their looks. A ticket ticket-manager left out is missing, and one that
    /// changed since its copy was fetched is fetched again, so its row's files stay current.
    private func refreshRows() async throws {
        guard let context else { return }
        let generation = self.generation
        if me == nil {
            _ = try? await refreshMe()
        }
        var ids: [String] = []
        for row in await context.state.rows where !ids.contains(row.item) && !malformed.contains(row.item) {
            ids.append(row.item)
        }
        let found = try await fetchSummaries(ids: ids)
        guard generation == self.generation else { return }
        let foundIDs = Set(found.map(\.id))
        for id in ids {
            await setMissing(id, !foundIDs.contains(id))
        }
        for summary in found where cached[summary.id].map({ Self.hasChanged($0.detail.ticket, summary) }) ?? true {
            schedule.queue(summary.id)
        }
        await store.setSummaries(found)
        await showLooks()
    }

    /// What ticket-manager changes when a ticket's conversation or handling does. `staleHours` alone grows every hour.
    private static func hasChanged(_ old: TicketSummary, _ new: TicketSummary) -> Bool {
        old.lastActivityAt != new.lastActivityAt || old.status != new.status || old.owner != new.owner
            || old.waiting != new.waiting || old.name != new.name
    }

    /// Each row's ticket.json, so the panel and the looks show at once after a relaunch.
    private func loadSavedTickets(_ context: PluginContext) async {
        for row in await context.state.rows where cached[row.item] == nil {
            guard let copy = TicketFiles.read(from: row.path) else { continue }
            cached[row.item] = copy
            if known[row.item] == nil { known[row.item] = copy.detail.ticket }
            await store.setDetail(copy.detail, fetchedAt: copy.fetchedAt)
        }
        await showLooks()
    }
}
