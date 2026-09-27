import Foundation
import Testing

@testable import CanopyCore

@MainActor
struct PaneTests {
    @Test func shellStartsInTheRowWithItsEnvironment() async throws {
        let dir = try TempDir()
        let row = dir.sub("my row")
        try FileManager.default.createDirectory(atPath: row, withIntermediateDirectories: true)
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }

        let pane = terminals.openTab(for: Fixture.context(row)).pane
        await pane.run(#"printf 'ready:%s:%s:%s\n' "$CANOPY_PANE" "$CANOPY_ROW" "$(pwd -P)""#)

        #expect(await eventually { pane.screen.text.contains("ready:p1:feat/x:\(row)") })
    }

    @Test func runTypesCommandsVerbatim() async throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }

        let pane = terminals.openTab(for: Fixture.context(dir.path)).pane
        await pane.run(#"printf '%s|%s\n' "it's" "héllo ✓ $CANOPY_ROW""#)

        #expect(await eventually { pane.screen.text.contains("it's|héllo ✓ feat/x") })
    }

    @Test func exitShowsItsCodeAndReturnRestarts() async throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let pane = terminals.openTab(for: Fixture.context(dir.path)).pane
        let firstShell = try #require(pane.pid)

        #expect(await eventually { pane.foreground?.name == "bash" })
        pane.refreshTitle()
        await pane.run("exit 3")
        #expect(await eventually { pane.status == .exited(3) })
        pane.refreshTitle()
        #expect(pane.title == "bash")
        #expect(pane.screen.text.hasSuffix("\u{1b}[?25l"))
        pane.screen.type("x")
        #expect(pane.status == .exited(3))
        pane.screen.type("\r")

        #expect(pane.status == .running)
        #expect(pane.pid != nil && pane.pid != firstShell)
        await pane.run("echo second-life")
        #expect(await eventually { pane.screen.text.contains("second-life\r\n") })
    }

    @Test func titleAndBusyFollowTheForegroundProgram() async throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }
        let pane = terminals.openTab(for: Fixture.context(dir.path)).pane
        #expect(await eventually { pane.foreground?.name == "bash" })

        pane.screen.onTitle?("my title")
        #expect(pane.title == "my title")
        #expect(!pane.isBusy)

        await pane.run("sleep 30")
        #expect(
            await eventually {
                pane.refreshTitle()
                return pane.title == "sleep"
            })
        #expect(pane.isBusy)
    }

    @Test func closingEndsTheProcessAndWakesWaiters() async throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        let pane = terminals.openTab(for: Fixture.context(dir.path), command: .script("sleep 30")).pane
        let group = try #require(pane.pid)
        let waiter = Task { await pane.waitForExit() }
        try await Task.sleep(for: .milliseconds(100))

        terminals.closePane(pane.id)

        #expect(await waiter.value == Pane.closedExitCode)
        #expect(await eventually { processGroupEnded(group) })
    }

    @Test func scriptReportsItsExitCode() async throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }

        let pane = terminals.openTab(for: Fixture.context(dir.path), command: .script("echo working; exit 4")).pane

        #expect(await pane.waitForExit() == 4)
        #expect(pane.screen.text.contains("working"))
        #expect(pane.title == "bash")
    }

    @Test func missingFolderStartsInHome() async throws {
        let dir = try TempDir()
        let terminals = Fixture.terminals(dir)
        defer { terminals.closeAll() }

        let pane = terminals.openTab(for: Fixture.context(dir.sub("gone"))).pane
        await pane.run(#"echo "at:$(pwd -P)""#)

        #expect(await eventually { pane.screen.text.contains("at:\(dir.sub("user-home"))") })
    }
}
