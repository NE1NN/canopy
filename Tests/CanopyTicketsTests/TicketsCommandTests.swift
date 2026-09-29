import CanopyCore
import Foundation
import Testing

@testable import CanopyTickets

@MainActor
struct TicketsCommandTests {
    let id853 = "0000000000000000000010001tickets"

    func connected(_ dir: TempDir) async throws -> TicketsHarness {
        let harness = try await TicketsHarness(dir, serverToken: "t")
        try await harness.connect(token: "t")
        return harness
    }

    @Test func listFiltersSortsAndNamesRows() async throws {
        let dir = try TempDir()
        let harness = try await connected(dir)
        let row = try await harness.newRow("853")

        func numbers(_ params: TicketListParams) async throws -> [String?] {
            try await harness.call(TicketMethod.list, params).decode([TicketListEntry].self).map(\.ticket.number)
        }
        #expect(try await numbers(TicketListParams()) == ["0853", "0850", "0849"])
        #expect(try await numbers(TicketListParams(owner: .mine)) == ["0853"])
        #expect(try await numbers(TicketListParams(owner: .unowned)) == ["0850"])
        #expect(try await numbers(TicketListParams(waiting: true)) == ["0853"])
        #expect(try await numbers(TicketListParams(query: "baba")) == ["0849"])
        #expect(try await numbers(TicketListParams(closed: true)) == ["0848", "0801"])
        let entries = try await harness.call(TicketMethod.list, TicketListParams()).decode([TicketListEntry].self)
        #expect(entries[0].row?.path == row.path && entries[1].row == nil)
    }

    @Test func newOpensAFilledRowAndRefusesASecond() async throws {
        let dir = try TempDir()
        let harness = try await connected(dir)

        let created = try await harness.call(TicketMethod.new, TicketNewParams(reference: "0853"))
            .decode(PluginRowCreated.self)

        #expect(created.row.title == "0853-sameergoyal" && created.row.item == id853)
        #expect(created.row.path.hasSuffix("/plugins/tickets/0853-sameergoyal"))
        #expect(created.fillError == nil && created.pane == nil)
        let markdown = try String(contentsOfFile: created.row.path + "/ticket.md", encoding: .utf8)
        #expect(markdown.contains("\n\n# Handover: ticket-0853-sameergoyal\n"))
        #expect(TicketFiles.read(from: created.row.path)?.detail.ticket.number == "0853")
        #expect(harness.store.ticket(id853).detail?.messages.count == 6)
        #expect(await harness.section()?.rows.first?.look.label == "#0853")
        await #expect { try await harness.call(TicketMethod.new, TicketNewParams(reference: "853")) } throws: {
            let error = $0 as? ControlError
            return error?.code == "ticket_has_row" && error?.message.contains(created.row.path) == true
        }
        await #expect { try await harness.call(TicketMethod.new, TicketNewParams(reference: "999")) } throws: {
            errorCode($0) == "ticket_not_found"
        }
    }

    @Test func theConfiguredRunStartsNewRows() async throws {
        let dir = try TempDir()
        let harness = try await connected(dir)
        defer { harness.close() }
        try await harness.setConfig(["run": "echo from-config"])
        let created = try await harness.call(TicketMethod.new, TicketNewParams(reference: "849"))
            .decode(PluginRowCreated.self)
        #expect(created.pane != nil)
        #expect(created.row.title == "0849-babamachine")
    }

    @Test func aFillWithoutTicketManagerFailsTheRowButKeepsIt() async throws {
        let dir = try TempDir()
        let harness = try await connected(dir)
        _ = try await harness.call(TicketMethod.list, TicketListParams())
        await harness.transport.fail("/api/v1/tickets/\(id853)", URLError(.cannotConnectToHost))
        let created = try await harness.call(TicketMethod.new, TicketNewParams(reference: id853))
            .decode(PluginRowCreated.self)
        #expect(created.fillError?.contains("Could not reach ticket-manager") == true)
        #expect(await harness.section()?.rows.count == 1)
    }

    @Test func referencesResolveNumbersNamesIdsAndClosedTickets() async throws {
        let dir = try TempDir()
        let harness = try await connected(dir)
        for reference in ["853", "#0853", "0853-sameergoyal", "ticket-0853-sameergoyal", id853] {
            #expect(
                try await harness.host.resolveLink(plugin: "tickets", reference: reference).item == id853,
                "\(reference)")
        }
        #expect(
            try await harness.host.resolveLink(plugin: "tickets", reference: "closed-0848-shathrem").item
                == "0000000000000000000010004tickets")
        #expect(
            try await harness.host.resolveLink(plugin: "tickets", reference: "801").item
                == "0000000000000000000010005tickets")
        for missing in ["999", "0853-nobody", "zzzz", "0000000000000000000010009tickets"] {
            await #expect("\(missing)") {
                try await harness.host.resolveLink(plugin: "tickets", reference: missing)
            } throws: {
                errorCode($0) == "ticket_not_found"
            }
        }
    }

    @Test func aMalformedIdIsNotFound() async throws {
        let dir = try TempDir()
        let harness = try await connected(dir)
        await harness.transport.markMalformed("not-an-id")
        await #expect { try await harness.host.resolveLink(plugin: "tickets", reference: "not-an-id") } throws: {
            errorCode($0) == "ticket_not_found"
        }
    }

    @Test func aNumberTwoTicketsShareIsAmbiguous() async throws {
        let dir = try TempDir()
        let harness = try await connected(dir)
        await harness.transport.addClosed(number: "0853", customer: "other", id: "0000000000000000000010009tickets")
        // Open tickets come first, so the closed one only counts once it has a row.
        #expect(try await harness.host.resolveLink(plugin: "tickets", reference: "853").item == id853)
        try await harness.newRow("0853-other")
        await #expect { try await harness.host.resolveLink(plugin: "tickets", reference: "853") } throws: {
            let error = $0 as? ControlError
            return error?.code == "ticket_ambiguous" && error?.message.contains("0853-other") == true
                && error?.message.contains("0853-sameergoyal") == true
        }
    }

    @Test func inATicketRowCommandsUseItsTicket() async throws {
        let dir = try TempDir()
        let harness = try await connected(dir)
        let row = try await harness.newRow("853")

        let shown = try await harness.call(TicketMethod.show, TicketShowParams(), in: row).decode(TicketShowResult.self)
        #expect(shown.ticket.ticket.number == "0853" && shown.row?.path == row.path && shown.stale == nil)
        let selected = try await harness.call(TicketMethod.select, TicketRefParams(), in: row).decode(PluginRow.self)
        #expect(selected.path == row.path && harness.ui.selected.last == row.path)
        await #expect { try await harness.call(TicketMethod.show, TicketShowParams()) } throws: {
            errorCode($0) == "bad_params"
        }
    }

    @Test func showUsesAFreshCopyAndFetchesAnOldOne() async throws {
        let dir = try TempDir()
        let harness = try await connected(dir)
        let row = try await harness.newRow("853")
        await harness.settle()
        await harness.transport.clearRequests()

        _ = try await harness.call(TicketMethod.show, TicketShowParams(), in: row)
        #expect(await harness.transport.requests.isEmpty)
        harness.clock.advance(by: .seconds(31))
        _ = try await harness.call(TicketMethod.show, TicketShowParams(), in: row)
        #expect(await harness.transport.requests.count == 1)
        _ = try await harness.call(TicketMethod.show, TicketShowParams(refresh: true), in: row)
        #expect(await harness.transport.requests.count == 2)
    }

    @Test func showsATicketWithoutARow() async throws {
        let dir = try TempDir()
        let harness = try await connected(dir)
        let shown = try await harness.call(TicketMethod.show, TicketShowParams(reference: "849"))
            .decode(TicketShowResult.self)
        #expect(shown.ticket.ticket.number == "0849" && shown.row == nil)
    }

    @Test func showFallsBackToTheCachedCopyWithItsAge() async throws {
        let dir = try TempDir()
        let harness = try await connected(dir)
        let row = try await harness.newRow("853")
        await harness.transport.failEverything(URLError(.cannotConnectToHost))
        harness.clock.advance(by: .seconds(300))

        let shown = try await harness.call(TicketMethod.show, TicketShowParams(refresh: true), in: row)
            .decode(TicketShowResult.self)
        #expect(shown.stale?.hasPrefix("Could not reach ticket-manager at") == true)
        #expect(shown.stale?.hasSuffix("This copy is from 5 min ago.") == true)
        await #expect { try await harness.call(TicketMethod.list, TicketListParams()) } throws: {
            errorCode($0) == "tickets_unreachable"
        }
        #expect(harness.store.ticket(id853).failure?.code == "tickets_unreachable")
        #expect(harness.store.ticket(id853).detail != nil)

        await harness.transport.failEverything(nil)
        _ = try await harness.call(TicketMethod.show, TicketShowParams(refresh: true), in: row)
        #expect(harness.store.ticket(id853).failure == nil)
    }

    @Test func showFallsBackToTheCachedCopyWhenTheAnswerCannotBeRead() async throws {
        let dir = try TempDir()
        let harness = try await connected(dir)
        let row = try await harness.newRow("853")
        var detail = try #require(
            JSONSerialization.jsonObject(with: APIFixture.data("ticket-detail")) as? [String: Any])
        var ticket = try #require(detail["ticket"] as? [String: Any])
        ticket["customer"] = NSNull()
        detail["ticket"] = ticket
        await harness.transport.set(
            "/api/v1/tickets/\(id853)",
            HTTPReply(status: 200, headers: [:], body: try JSONSerialization.data(withJSONObject: detail)))
        harness.clock.advance(by: .seconds(300))

        let shown = try await harness.call(TicketMethod.show, TicketShowParams(refresh: true), in: row)
            .decode(TicketShowResult.self)
        #expect(shown.ticket.ticket.customer == "sameergoyal")
        #expect(shown.stale?.contains("`ticket.customer` is null") == true)
        #expect(shown.stale?.hasSuffix("This copy is from 5 min ago.") == true)
        #expect(harness.store.ticket(id853).failure?.code == "unreadable_answer")
    }

    @Test func selectAndRemoveWorkFromRowsAlone() async throws {
        let dir = try TempDir()
        let harness = try await connected(dir)
        let row = try await harness.newRow("853")
        await harness.transport.failEverything(URLError(.cannotConnectToHost))

        let selected = try await harness.call(TicketMethod.select, TicketRefParams(reference: "853"))
            .decode(PluginRow.self)
        #expect(selected.path == row.path)
        let removed = try await harness.call(TicketMethod.remove, TicketRemoveParams(reference: "0853-sameergoyal"))
            .decode(PluginRowRemoved.self)
        #expect(removed.row.path == row.path && removed.trashedTo?.hasPrefix(dir.sub("trash")) == true)
        #expect(await harness.section()?.rows.isEmpty == true)
    }

    @Test func removingARowWithAProgramRunningAsksFirst() async throws {
        let dir = try TempDir()
        let harness = try await connected(dir)
        defer { harness.close() }
        let row = try await harness.newRow("853")
        await harness.runBusyProgram(in: row)
        await #expect { try await harness.call(TicketMethod.remove, TicketRemoveParams(), in: row) } throws: {
            errorCode($0) == "row_busy"
        }
        _ = try await harness.call(TicketMethod.remove, TicketRemoveParams(force: true), in: row)
        #expect(await harness.section()?.rows.isEmpty == true)
    }

    @Test func selectingATicketWithoutARowSaysHowToOpenOne() async throws {
        let dir = try TempDir()
        let harness = try await connected(dir)
        await #expect { try await harness.call(TicketMethod.select, TicketRefParams(reference: "850")) } throws: {
            let error = $0 as? ControlError
            return error?.code == "ticket_has_no_row"
                && error?.message.contains("canopy ticket new 0850-quietcustomer") == true
        }
    }

    @Test func aTicketThatIsGoneShowsItsRowMissing() async throws {
        let dir = try TempDir()
        let harness = try await connected(dir)
        let row = try await harness.newRow("853")
        await harness.transport.remove(row.item)

        await #expect { try await harness.call(TicketMethod.show, TicketShowParams(refresh: true), in: row) } throws: {
            errorCode($0) == "ticket_not_found"
        }
        #expect(await harness.section()?.rows.first?.isMissing == true)
        #expect(harness.store.ticket(row.item).isMissing)
    }

    @Test func thePickerListsOpenOrClosedAndNarrowsWithoutFetching() async throws {
        let dir = try TempDir()
        let harness = try await connected(dir)
        func titles(_ text: String, _ choice: String, _ toggles: Set<String>, fresh: Bool) async throws -> [String] {
            try await harness.host.items(
                "tickets", matching: PluginQuery(text: text, choice: choice, toggles: toggles, fresh: fresh)
            ).map(\.title)
        }
        #expect(
            try await titles("", "anyone", [], fresh: true) == [
                "0853-sameergoyal", "0850-quietcustomer", "0849-babamachine",
            ])
        await harness.settle()
        let before = await harness.transport.requests.count
        #expect(try await titles("quiet", "anyone", [], fresh: false) == ["0850-quietcustomer"])
        #expect(try await titles("", "mine", [], fresh: false) == ["0853-sameergoyal"])
        #expect(try await titles("", "unowned", [], fresh: false) == ["0850-quietcustomer"])
        #expect(await harness.transport.requests.count == before)
        #expect(try await titles("", "anyone", ["closed"], fresh: true) == ["0848-shathrem", "0801-oldco"])
        #expect(
            harness.plugin.pickerCommand(for: .create(PluginItem(id: "x", title: "0853-sameergoyal")))
                == "canopy ticket new 0853-sameergoyal --select")
        let row = PluginRow(
            plugin: "tickets", item: "k57", title: "0855-mayaperez", path: "/h/plugins/tickets/0855-mayaperez")
        #expect(harness.plugin.pickerCommand(for: .select(row)) == "canopy ticket select 0855-mayaperez")
        let odd = PluginRow(plugin: "tickets", item: "k58", title: "general help", path: "/h/plugins/tickets/general")
        #expect(harness.plugin.pickerCommand(for: .select(odd)) == "canopy ticket select k58")
        #expect(
            harness.plugin.pickerCommand(for: .create(PluginItem(id: "k59", title: "it's odd")))
                == "canopy ticket new k59 --select")
    }
}
