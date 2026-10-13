import XCTest

/// Walks every screen of the app against a dev build from scripts/phone-fixture.sh, answering its agents along the
/// way, and keeps a screenshot of each. scripts/ios-shots.sh runs it and sets:
///
/// - `CANOPY_TOUR_LINK`: a pairing link from the fixture's Mac.
/// - `CANOPY_TOUR_BOX_LINK`: one from the fixture's box, paired second.
/// - `CANOPY_TOUR_DIR`: a folder on the Mac the tour leaves requests in, `stop-mac` and `restart-mac`, which the
///   script carries out, since only the Mac can stop its Canopy.
@MainActor
final class ScreenTour: XCTestCase {
    private var app: XCUIApplication!
    private var step = 0

    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testEveryScreen() throws {
        let environment = ProcessInfo.processInfo.environment
        let link = try XCTUnwrap(environment["CANOPY_TOUR_LINK"].flatMap(URL.init(string:)), "CANOPY_TOUR_LINK")
        let boxLink = try XCTUnwrap(
            environment["CANOPY_TOUR_BOX_LINK"].flatMap(URL.init(string:)), "CANOPY_TOUR_BOX_LINK")
        let requests = try XCTUnwrap(environment["CANOPY_TOUR_DIR"].map(URL.init(fileURLWithPath:)), "CANOPY_TOUR_DIR")

        app = XCUIApplication()
        app.launchEnvironment["CANOPY_TOUR_EC2"] = environment["CANOPY_TOUR_EC2"]
        app.launchArguments = ["-ScreenTour", "-ScreenTourReset"]
        app.launch()
        XCTAssert(app.staticTexts["Pair with your Mac"].waitForExistence(timeout: 10), "no Pairing at first")
        shot("pairing")

        // The link opens the app as the camera's scan would, through its URL scheme.
        open(link)
        XCTAssert(
            app.staticTexts.matching(identifier: "connection").firstMatch.waitForExistence(timeout: 15),
            "the link did not pair")
        XCTAssert(wait { self.app.staticTexts["connection"].label.contains("connected") }, "never connected")
        XCTAssert(element("item-feat/ios-companion").waitForExistence(timeout: 10), "no waiting agent in the Inbox")
        XCTAssert(element("item-fix/port-scan-drain").exists, "the done agent is not in the Inbox")
        XCTAssertFalse(element("item-feat/port-labels").exists, "a working agent is in the Inbox")
        // The Mac lists the box's row too, as one of its remote rows, until the phone pairs with the box.
        XCTAssert(element("item-feat/usage-migration").waitForExistence(timeout: 10), "no box row from the Mac")

        // A second server, from Settings: the camera's screen, then the box's link.
        app.buttons["settings"].tap()
        app.buttons["pair-another"].tap()
        XCTAssert(app.staticTexts["Pair another server"].waitForExistence(timeout: 5), "no Pair another server")
        shot("pair-another")
        app.buttons["Cancel"].tap()
        app.navigationBars["Settings"].buttons["Done"].tap()
        open(boxLink)
        XCTAssert(
            wait(timeout: 20) { self.app.staticTexts["connection"].label.contains(" and devbox connected") },
            "the box never connected")
        XCTAssert(element("item-feat/usage-migration").waitForExistence(timeout: 10), "no box agent in the Inbox")
        // Counted against a row only the Mac has, as an item can be more than one element in the tree.
        XCTAssertEqual(
            items("item-feat/usage-migration"), items("item-fix/port-scan-drain"),
            "the box's row shows from the Mac and the box")
        shot("inbox")

        app.tabBars.buttons["Rows"].tap()
        XCTAssert(element("main-canopy").waitForExistence(timeout: 10), "Rows has no main card")
        XCTAssert(element("row-fix/hand-checks").exists, "Rows has no idle row")
        let hosts = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'host-'"))
        XCTAssert(hosts.firstMatch.label.contains("connected"), "Rows does not say the Mac is connected")
        shot("rows")
        app.swipeUp()
        XCTAssert(element("row-feat/usage-migration").waitForExistence(timeout: 5), "Rows has no box row")
        XCTAssert(element("host-devbox").label.contains("connected"), "Rows does not say the box is connected")
        XCTAssertEqual(
            items("row-feat/usage-migration"), items("row-fix/hand-checks"),
            "the box's row shows under the Mac and the box")
        shot("rows-box")
        app.swipeDown()
        app.tabBars.buttons["Inbox"].tap()

        // The box's agent, read through the box, names its host.
        self.open("item-feat/usage-migration")
        XCTAssert(text("staging migrated, totals match").waitForExistence(timeout: 10), "no box transcript")
        XCTAssert(element("title").label.contains("devbox"), "the conversation does not name the box")
        shot("conversation-box")
        app.navigationBars.buttons["Inbox"].tap()
        XCTAssert(wait { !self.element("item-feat/usage-migration").exists }, "opening the box's agent left it unread")

        // The box powers itself off: a card offers to wake it, and waking it through EC2 brings Canopy there back.
        request("stop-box", in: requests)
        XCTAssert(element("wake-devbox").waitForExistence(timeout: 30), "no Wake card once the box stopped")
        shot("inbox-box-off")
        let wake = app.buttons["wake-devbox"]
        XCTAssert(wait { wake.isHittable }, "Wake cannot be tapped")
        wake.tap()
        XCTAssert(text("Waking devbox").waitForExistence(timeout: 5), "the card does not say it is waking")
        shot("inbox-box-waking")
        XCTAssert(wait(timeout: 90) { !self.element("wake-card-devbox").exists }, "the box never came back")
        XCTAssert(
            wait(timeout: 30) { self.app.staticTexts["connection"].label.contains("devbox connected") },
            "the box did not connect again")

        // New task on the box: its agent starts on the brief, and the phone lands in its conversation.
        app.buttons["new-task"].tap()
        XCTAssert(app.navigationBars["New task"].waitForExistence(timeout: 5), "New task did not open")
        app.buttons["where-devbox"].tap()
        XCTAssert(wait { self.app.buttons["where-devbox"].isSelected }, "Where did not choose the box")
        let branch = app.textFields["task-branch"]
        branch.tap()
        branch.typeText("feat/health-check")
        let brief = app.textViews["task-brief"].exists ? app.textViews["task-brief"] : app.textFields["task-brief"]
        brief.tap()
        brief.typeText("Add a health check to the usage page, next to the totals.")
        // Done above the keyboard puts it away, as Return in the brief starts a new line.
        app.buttons["keyboard-done"].tap()
        XCTAssert(wait { !self.app.keyboards.firstMatch.exists }, "the keyboard stayed up")
        shot("new-task")
        app.buttons["task-start"].tap()
        XCTAssert(
            text("Add a health check to the usage page").waitForExistence(timeout: 30),
            "the task's conversation did not open with its brief")
        XCTAssert(
            text("The health check goes next to the totals.").waitForExistence(timeout: 20),
            "the task's agent never answered")
        XCTAssert(element("title").label.contains("devbox"), "the task's conversation does not name the box")
        shot("conversation-new-task")
        app.navigationBars.buttons["Inbox"].tap()

        // A question with options, answered with a chip.
        self.open("item-feat/ios-companion")
        XCTAssert(app.buttons["option-Tailscale"].waitForExistence(timeout: 10), "no option chips")
        XCTAssert(text("It needs a way in from outside your network.").waitForExistence(timeout: 10), "no transcript")
        shot("conversation")

        app.buttons["Terminal"].tap()
        XCTAssert(app.descendants(matching: .any)["terminal"].waitForExistence(timeout: 10), "no terminal")
        XCTAssert(text("Tailscale").waitForExistence(timeout: 10), "the terminal shows no screen")
        shot("terminal")
        app.buttons["Keyboard"].tap()
        XCTAssert(app.keyboards.firstMatch.waitForExistence(timeout: 5), "no keyboard for the terminal")
        shot("terminal-keyboard")
        app.buttons["Hide keyboard"].tap()
        app.buttons["Chat"].tap()

        app.buttons["option-Tailscale"].tap()
        XCTAssert(text("Going with Tailscale.").waitForExistence(timeout: 15), "the answer never reached the agent")
        XCTAssertFalse(app.buttons["option-Tailscale"].exists, "the answered question still offers options")

        // A reply, Sent and then Delivered as the agent takes it.
        let reply = app.textViews["reply"].exists ? app.textViews["reply"] : app.textFields["reply"]
        reply.tap()
        reply.typeText("Use port 6974, and keep the token in the Keychain.")
        app.buttons["send"].tap()
        XCTAssert(text("On it: Use port 6974").waitForExistence(timeout: 15), "the reply never reached the agent")
        // Scrolling the conversation puts the keyboard away.
        let chat = app.scrollViews["chat"]
        XCTAssert(chat.exists, "the chat has no scroll view")
        chat.swipeDown()
        XCTAssert(wait { !self.hasFocus(reply) }, "the keyboard stayed up")
        shot("conversation-answered")
        app.navigationBars.buttons["Inbox"].tap()

        // Allow straight from the list.
        let allow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'allow-'")).firstMatch
        XCTAssert(allow.waitForExistence(timeout: 10), "no Allow in the inbox")
        allow.tap()
        XCTAssert(wait(timeout: 20) { !allow.exists }, "Allow stayed")
        XCTAssert(
            wait(timeout: 20) { self.text("Deployed. The usage page shows fresh totals now.").exists },
            "the allowed command never ran")
        shot("inbox-answered")

        // Read from the list: one by a swipe, then the rest at once, until nothing is left.
        let drain = element("item-fix/port-scan-drain")
        XCTAssert(drain.waitForExistence(timeout: 10), "the done agent left before it was read")
        drain.swipeLeft()
        app.buttons["mark-read-fix/port-scan-drain"].tap()
        XCTAssert(wait { !drain.exists }, "Mark read did not remove the item")
        // The ticket's agent is in Done by now: its last line shows only once it is done.
        let markAll = app.buttons["mark-all-read"]
        XCTAssert(markAll.waitForExistence(timeout: 10), "no Mark all read for the ticket's done agent")
        markAll.tap()
        XCTAssert(element("caught-up").waitForExistence(timeout: 30), "the Inbox never emptied")
        shot("inbox-caught-up")
        app.buttons["see-rows"].tap()
        XCTAssert(element("main-canopy").waitForExistence(timeout: 5), "See rows did not open Rows")
        app.tabBars.buttons["Inbox"].tap()

        app.buttons["settings"].tap()
        XCTAssert(app.navigationBars["Settings"].waitForExistence(timeout: 5), "Settings did not open")
        XCTAssert(element("server-devbox").exists, "Settings does not list the box")
        shot("settings")
        element("server-devbox").tap()
        XCTAssert(app.buttons["remove-server"].waitForExistence(timeout: 5), "no server detail")
        shot("settings-server")
        app.navigationBars["devbox"].buttons.element(boundBy: 0).tap()
        // Away and back with Settings open: the lock covers the sheet too, so its switch cannot turn the lock off.
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssert(app.staticTexts["Canopy is locked"].waitForExistence(timeout: 10), "no lock over Settings")
        XCTAssertFalse(app.switches["lock-toggle"].isHittable, "the lock switch is usable under the lock")
        shot("locked-over-settings")
        app.buttons["unlock"].tap()
        XCTAssert(wait { !self.app.staticTexts["Canopy is locked"].exists }, "Unlock did not open the app")
        app.navigationBars["Settings"].buttons["Done"].tap()

        // A later launch is paired, so it opens locked.
        app.terminate()
        app.launchArguments = ["-ScreenTour"]
        app.launch()
        XCTAssert(app.staticTexts["Canopy is locked"].waitForExistence(timeout: 10), "a paired launch is not locked")
        shot("locked")
        app.buttons["unlock"].tap()
        XCTAssert(app.staticTexts["connection"].waitForExistence(timeout: 15), "Unlock did not open the inbox")

        // The Mac and the box go away: the last inbox stays, greyed, with what to check.
        request("stop-mac", in: requests)
        XCTAssert(
            app.descendants(matching: .any)["banner"].waitForExistence(timeout: 30), "no banner once the Mac stopped")
        XCTAssert(
            wait { self.app.staticTexts["connection"].label.hasPrefix("As of") },
            "the inbox does not say when it is from")
        shot("unreachable")

        // Servers that no longer know the phone send it back to Pairing.
        request("restart-mac", in: requests)
        XCTAssert(app.staticTexts["Pair with your Mac"].waitForExistence(timeout: 90), "an unpaired phone stayed")
        XCTAssert(text("no longer know this iPhone").exists, "Pairing does not say why")
        shot("unpaired")
    }

    /// Opens a pairing link through the app's URL scheme, as the camera's scan would.
    private func open(_ link: URL) {
        XCUIDevice.shared.system.open(link)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.buttons["Open"].waitForExistence(timeout: 5) { springboard.buttons["Open"].tap() }
    }

    private func items(_ identifier: String) -> Int {
        app.descendants(matching: .any).matching(identifier: identifier).count
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Text on screen containing `part`. Queries by whole label are limited to 128 characters.
    private func text(_ part: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", part)).firstMatch
    }

    private func hasFocus(_ element: XCUIElement) -> Bool {
        (element.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
    }

    private func open(_ identifier: String) {
        let item = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        XCTAssert(item.waitForExistence(timeout: 10), identifier)
        item.tap()
    }

    private func shot(_ name: String) {
        // Let pulses and transitions settle into a still frame.
        Thread.sleep(forTimeInterval: 1)
        step += 1
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = String(format: "%02d-%@", step, name)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func request(_ name: String, in folder: URL) {
        FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data())
    }

    private func wait(timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }
}
