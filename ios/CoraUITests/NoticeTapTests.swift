import XCTest

/// Taps real notifications on the simulator, posted by the sample space with the payload a space sends, and checks the screen each one opens:
/// with the app closed, in the background and in front, for spaces that name the target and for older ones that send only the panel link.
final class NoticeTapTests: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUp() {
        continueAfterFailure = false
    }

    /// Launches the sample space on the Spaces tab, which no notification opens, and lets it post `payload` after `delay` seconds.
    private func launch(_ payload: [String: String], delay: Int) -> XCUIApplication {
        let app = XCUIApplication()
        let json = String(data: try! JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
        app.launchEnvironment = ["CORA_DEMO": "1", "CORA_DEMO_STICKY": "1", "CORA_DEMO_TAB": "spaces", "CORA_DEMO_NOTICE": json, "CORA_DEMO_NOTICE_DELAY": String(delay)]
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let allow = springboard.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
        XCTAssert(app.navigationBars["Spaces"].waitForExistence(timeout: 10), "the app starts on the Spaces tab")
        return app
    }

    private func tapNotification(_ title: String) {
        let banner = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        XCTAssert(banner.waitForExistence(timeout: 25), "the notification «\(title)» appears")
        snapshot("banner \(title)")
        banner.tap()
    }

    private func snapshot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func expectScreen(_ app: XCUIApplication, title: String, _ name: String) {
        XCTAssert(app.wait(for: .runningForeground, timeout: 15), "the tap brings Cora to the front")
        XCTAssert(app.navigationBars[title].waitForExistence(timeout: 15), "the tap opens «\(title)»")
        snapshot(name)
    }

    func testA_PlanWithTheAppClosed() {
        let app = launch(["title": "Buzz is blocked", "body": "Q3 report for the team", "planId": "plan_buzz", "channelId": "1000000000000000001", "kind": "plan-blocked", "url": "/#/thread/t/1000000000000000001", "space": "https://acme.usecora.space"], delay: 12)
        app.terminate()
        XCTAssertEqual(app.state, .notRunning)
        tapNotification("Buzz is blocked")
        expectScreen(app, title: "Q3 report for the team", "plan opened from a closed app")
    }

    func testB_ThreadWithTheAppInTheBackground() {
        let app = launch(["title": "Buzz in Quarterly report", "body": "The report is ready", "channelId": "1000000000000000001", "kind": "thread", "url": "/#/thread/t/1000000000000000001", "space": "https://acme.usecora.space"], delay: 12)
        XCUIDevice.shared.press(.home)
        tapNotification("Buzz in Quarterly report")
        expectScreen(app, title: "Quarterly report", "thread opened from the background")
    }

    func testC_AgentFromAnOlderSpaceWithTheAppInFront() {
        let app = launch(["title": "Buzz: done", "body": "Released", "url": "/#/agent/ag_buzz/chat"], delay: 3)
        tapNotification("Buzz: done")
        expectScreen(app, title: "Buzz", "agent opened from a notice with only the panel link")
    }

    func testD_QuotaOpensTheSubscriptions() {
        let app = launch(["title": "Claude Max: 25% left", "body": "Session", "kind": "quota", "url": "/"], delay: 12)
        XCUIDevice.shared.press(.home)
        tapNotification("Claude Max: 25% left")
        expectScreen(app, title: "Subscriptions", "subscriptions opened from a quota alert")
    }

    func testE_PanelPageOpensInTheBrowser() {
        _ = launch(["title": "Vault", "body": "A secret arrived", "kind": "panel", "url": "/#/artefatti/segreti", "space": "https://acme.usecora.space", "link": "https://acme.usecora.space/#/artefatti/segreti"], delay: 12)
        XCUIDevice.shared.press(.home)
        tapNotification("Vault")
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssert(safari.wait(for: .runningForeground, timeout: 20), "a panel page opens in Safari")
        snapshot("panel page opened in Safari")
    }
}
