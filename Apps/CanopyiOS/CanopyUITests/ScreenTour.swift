import XCTest

/// Walks every screen of the app against a dev build from scripts/phone-fixture.sh, answering its agents along the
/// way, and keeps a screenshot of each. scripts/ios-shots.sh runs it and sets:
///
/// - `CANOPY_TOUR_LINK`: a pairing link from the fixture.
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
        let requests = try XCTUnwrap(environment["CANOPY_TOUR_DIR"].map(URL.init(fileURLWithPath:)), "CANOPY_TOUR_DIR")

        app = XCUIApplication()
        app.launchArguments = ["-ScreenTour", "-ScreenTourReset"]
        app.launch()
        XCTAssert(app.staticTexts["Pair with your Mac"].waitForExistence(timeout: 10), "step at line 26")
        shot("pairing")

        // The link opens the app as the camera's scan would, through its URL scheme.
        XCUIDevice.shared.system.open(link)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.buttons["Open"].waitForExistence(timeout: 5) { springboard.buttons["Open"].tap() }
        XCTAssert(
            app.staticTexts.matching(identifier: "connection").firstMatch.waitForExistence(timeout: 15),
            "step at line 33")
        XCTAssert(wait { self.app.staticTexts["connection"].label.contains("connected") }, "step at line 34")
        XCTAssert(app.descendants(matching: .any)["pinned-main"].waitForExistence(timeout: 10), "step at line 35")
        shot("inbox")

        app.tabBars.buttons["Rows"].tap()
        XCTAssert(
            app.descendants(matching: .any)["row-fix/hand-checks"].waitForExistence(timeout: 10), "step at line 39")
        shot("rows")
        app.tabBars.buttons["Inbox"].tap()

        // A question with options, answered with a chip.
        open("item-feat/ios-companion")
        XCTAssert(app.buttons["option-Tailscale"].waitForExistence(timeout: 10), "step at line 45")
        XCTAssert(text("It needs a way in from outside your network.").waitForExistence(timeout: 10), "step at line 46")
        shot("conversation")

        app.buttons["Terminal"].tap()
        XCTAssert(app.descendants(matching: .any)["terminal"].waitForExistence(timeout: 10), "step at line 50")
        XCTAssert(text("Tailscale").waitForExistence(timeout: 10), "step at line 51")
        shot("terminal")
        app.buttons["Keyboard"].tap()
        XCTAssert(app.keyboards.firstMatch.waitForExistence(timeout: 5), "step at line 54")
        shot("terminal-keyboard")
        app.buttons["Hide keyboard"].tap()
        app.buttons["Chat"].tap()

        app.buttons["option-Tailscale"].tap()
        XCTAssert(text("Going with Tailscale.").waitForExistence(timeout: 15), "step at line 60")
        XCTAssertFalse(app.buttons["option-Tailscale"].exists, "step at line 61")

        // A reply, Sent and then Delivered as the agent takes it.
        let reply = app.textViews["reply"].exists ? app.textViews["reply"] : app.textFields["reply"]
        reply.tap()
        reply.typeText("Use port 6974, and keep the token in the Keychain.")
        app.buttons["send"].tap()
        XCTAssert(text("On it: Use port 6974").waitForExistence(timeout: 15), "step at line 68")
        // Scrolling the conversation puts the keyboard away.
        let chat = app.scrollViews["chat"]
        XCTAssert(chat.exists, "the chat has no scroll view")
        chat.swipeDown()
        XCTAssert(wait { !self.hasFocus(reply) }, "the keyboard stayed up")
        shot("conversation-answered")
        app.navigationBars.buttons["Inbox"].tap()

        // Allow straight from the list.
        let allow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'allow-'")).firstMatch
        XCTAssert(allow.waitForExistence(timeout: 10), "step at line 76")
        allow.tap()
        XCTAssert(wait(timeout: 20) { !allow.exists }, "step at line 78")
        XCTAssert(
            wait(timeout: 20) { self.text("Deployed. The usage page shows fresh totals now.").exists }, "no Deployed")
        shot("inbox-answered")

        app.buttons["settings"].tap()
        XCTAssert(app.navigationBars["Settings"].waitForExistence(timeout: 5), "step at line 85")
        shot("settings")
        app.navigationBars["Settings"].buttons["Done"].tap()

        // A later launch is paired, so it opens locked.
        app.terminate()
        app.launchArguments = ["-ScreenTour"]
        app.launch()
        XCTAssert(app.staticTexts["Canopy is locked"].waitForExistence(timeout: 10), "step at line 93")
        shot("locked")
        app.buttons["unlock"].tap()
        XCTAssert(app.descendants(matching: .any)["pinned-main"].waitForExistence(timeout: 15), "step at line 96")

        // The Mac goes away: the last inbox stays, greyed, with what to check.
        request("stop-mac", in: requests)
        XCTAssert(app.descendants(matching: .any)["banner"].waitForExistence(timeout: 30), "step at line 100")
        XCTAssert(wait { self.app.staticTexts["connection"].label.hasPrefix("As of") }, "step at line 101")
        shot("unreachable")

        // A Mac that no longer knows the phone sends it back to Pairing.
        request("restart-mac", in: requests)
        XCTAssert(app.staticTexts["Pair with your Mac"].waitForExistence(timeout: 90), "step at line 106")
        XCTAssert(text("no longer knows this iPhone").exists, "step at line 107")
        shot("unpaired")
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
