import XCTest

private extension XCUIElement {
    func pressControl() {
        #if os(macOS)
        click()
        #else
        tap()
        #endif
    }
}

final class ClosePlanTests: XCTestCase {
    private func text(_ path: String) throws -> String {
        try String(contentsOf: URL(string: "http://127.0.0.1:19428/" + path)!, encoding: .utf8)
    }
    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    func testOwnerClosesConfirmedPlan() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(it)", "-AppleLocale", "it_IT"]
        #if os(macOS)
        app.launchEnvironment["CORA_APP_HOME"] = "/tmp/cora-fab-native-test"
        #endif
        app.launch()
        #if os(iOS)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let permission = springboard.alerts.buttons.matching(NSPredicate(format: "label IN %@", ["Allow", "Consenti", "Don’t Allow", "Non consentire"])).firstMatch
        if permission.waitForExistence(timeout: 5) { permission.tap() }
        let plans = app.tabBars.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Piani")).firstMatch
        XCTAssertTrue(plans.waitForExistence(timeout: 15), app.debugDescription)
        plans.tap()
        let namedRow = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Verifica chiusura")).firstMatch
        if namedRow.waitForExistence(timeout: 5) { namedRow.tap() }
        else { app.staticTexts["Verifica chiusura"].tap() }
        #endif
        let close = app.buttons["Chiudi piano"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 20), app.debugDescription)
        shot("01-piano-aperto")
        close.pressControl()
        #if os(macOS)
        let confirm = app.buttons["action-button-1"]
        let cancel = app.buttons["action-button-2"]
        #else
        let confirm = app.buttons["Conferma chiusura"].firstMatch
        let cancel = app.buttons["Annulla"].firstMatch
        #endif
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
        shot("02-conferma")
        cancel.pressControl()
        XCTAssertEqual(try text("state"), "active/1/2")
        close.pressControl()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.pressControl()
        XCTAssertTrue(close.waitForNonExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(try text("state"), "closed/1/2")
        shot("03-piano-chiuso")
        #if os(macOS)
        // Scroll bars and progress indicators carry numeric values: a substring predicate over every element raises inside the app.
        let status = app.staticTexts.matching(NSPredicate(format: "value CONTAINS[c] 'Chiuso' OR label CONTAINS[c] 'Chiuso'")).firstMatch
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Chiuso' OR title CONTAINS[c] 'Chiuso'")).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 8) || row.exists, app.debugDescription)
        #else
        let status = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'Chiuso' OR value CONTAINS[c] 'Chiuso'")).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 8), app.debugDescription)
        #endif
        shot("04-storico")
    }
}
