import XCTest

/// Sets a question aside from the Agents tab of the sample space: the cross removes it, a swipe offers Ignore for the next one.
final class QuestionTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testIgnoreAQuestion() {
        let app = XCUIApplication()
        app.launchEnvironment = ["CORA_DEMO": "1", "CORA_DEMO_QUESTIONS": "1", "CORA_DEMO_TAB": "agents"]
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let first = app.staticTexts["Buzz asks you"]
        XCTAssert(first.waitForExistence(timeout: 15), "the question of Buzz is listed")
        let crosses = app.buttons.matching(identifier: "Ignore")
        let before = crosses.count
        XCTAssertGreaterThan(before, 0, "every question has its Ignore cross")
        shot("questions before ignoring")
        crosses.firstMatch.tap()
        XCTAssert(first.waitForNonExistence(timeout: 5), "the ignored question leaves the list")
        XCTAssertEqual(app.buttons.matching(identifier: "Ignore").count, before - 1, "the others stay")
        shot("one question ignored")
        let second = app.staticTexts["Ada asks you"]
        XCTAssert(second.exists, "the next question is still there")
        second.swipeLeft()
        let offered = expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: app.buttons.matching(identifier: "Ignore"))
        wait(for: [offered], timeout: 5)
        let swiped = app.buttons.matching(identifier: "Ignore").element(boundBy: 1)
        shot("swipe offers Ignore")
        swiped.tap()
        XCTAssert(second.waitForNonExistence(timeout: 5), "ignored with a swipe, it leaves the list")
        shot("second question ignored with a swipe")
    }
}
