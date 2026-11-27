import XCTest

final class SpacePanelTests: XCTestCase {
    private let app = XCUIApplication()
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    private func take(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func confirmInBrowser() {
        let consent = springboard.buttons["Continue"]
        if consent.waitForExistence(timeout: 2) { consent.tap() }
        let password = app.secureTextFields.firstMatch
        let authorize = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Authorize the panel' OR label CONTAINS[c] 'Autorizza il pannello'")).firstMatch
        let signInLoaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            password.exists || authorize.exists
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [signInLoaded], timeout: 25), .completed)
        if password.exists {
            password.tap()
            password.typeText("fixture-password\n")
        }
        XCTAssertTrue(authorize.waitForExistence(timeout: 15))
        take("01 - Autorizzazione del pannello")
        authorize.tap()
    }

    func testPanelPairingAndNavigation() throws {
        guard let input = ProcessInfo.processInfo.environment["CORA_TEST_SPACE_URL"], let origin = URL(string: input),
              origin.host == "127.0.0.1" else { throw XCTSkip("Requires a running loopback Cora fixture.") }
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        continueAfterFailure = false
        if !app.buttons["app-tabs"].waitForExistence(timeout: 2) {
            let host = app.textFields.firstMatch
            host.tap()
            host.typeText(origin.absoluteString)
            app.buttons["Connect"].tap()
            confirmInBrowser()
        }
        if app.buttons["Authorize this iPhone"].waitForExistence(timeout: 1) {
            app.buttons["Authorize this iPhone"].tap()
            confirmInBrowser()
        }
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
        let panel = app.webViews.firstMatch
        let agent = panel.descendants(matching: .any).matching(NSPredicate(format: "label == 'Luna'")).firstMatch
        XCTAssertTrue(agent.waitForExistence(timeout: 25), "real agent in the authenticated space")
        XCTAssertFalse(app.tabBars.firstMatch.isHittable)
        take("02 - Lo spazio su iPhone")
        app.buttons["app-tabs"].tap()
        XCTAssertTrue(app.tabBars.buttons["Space"].isHittable)
        take("03 - I tab nativi")
        app.tabBars.buttons["Space"].tap()
        XCTAssertTrue(agent.waitForExistence(timeout: 10))
        app.terminate()
        app.launch()
        XCTAssertTrue(agent.waitForExistence(timeout: 20), "web session restored after relaunch")

        guard let second = ProcessInfo.processInfo.environment["CORA_TEST_SECOND_SPACE_URL"].flatMap(URL.init(string:)),
              second.host == "127.0.0.1" else { return }
        app.buttons["space-menu"].tap()
        app.buttons["Spaces"].tap()
        let existing = app.buttons["choose-space-" + second.absoluteString]
        if existing.exists {
            existing.tap()
        } else {
            app.buttons["Add a space"].tap()
            let field = app.textFields.firstMatch
            field.tap()
            field.typeText(second.absoluteString)
            app.buttons["Connect"].tap()
            confirmInBrowser()
            let done = app.buttons["Done"]
            XCTAssertTrue(done.waitForExistence(timeout: 15))
            done.tap()
        }
        let otherAgent = panel.staticTexts["Atlante"].firstMatch
        XCTAssertTrue(otherAgent.waitForExistence(timeout: 15))
        XCTAssertFalse(agent.exists)
        take("04 - Il secondo spazio")
        app.terminate()
        app.launch()
        XCTAssertTrue(otherAgent.waitForExistence(timeout: 20), "the selected space survives relaunch")
        app.buttons["space-menu"].tap()
        app.buttons["127.0.0.1:\(try XCTUnwrap(origin.port))"].tap()
        XCTAssertTrue(agent.waitForExistence(timeout: 15))
        XCTAssertFalse(otherAgent.exists)
    }
}
