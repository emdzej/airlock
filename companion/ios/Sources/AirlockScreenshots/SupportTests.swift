import XCTest

/// Report a Problem against the live ALIAS desk, on the demo airlock (no
/// real airlock, names or files on screen). Needs a build with a product
/// key. testReport sends a report; after support answers it,
/// testAnswer opens the thread. Screenshots go to $SCREENSHOT_DIR.
final class SupportTests: XCTestCase {
    private var app: XCUIApplication!
    private var outDir: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] ?? NSTemporaryDirectory()
        outDir = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
    }

    func testReport() throws {
        openReport()
        let note = app.textViews.firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        note.tap()
        note.typeText("Ejected the SD card, but the drive stays listed as mounted until I pull the reader out.")
        tapDone()
        settle()
        snap("01-report")

        app.buttons["Black out parts"].firstMatch.tap()
        let canvas = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ AND elementType != %d", "Black out what you don't want to send",
                                  XCUIElement.ElementType.staticText.rawValue)).firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        let from = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.2))
        let to = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.3))
        from.press(forDuration: 0.1, thenDragTo: to)
        settle()
        snap("01b-redact")
        app.buttons["Done"].firstMatch.tap()
        settle(1)

        app.swipeUp()
        app.buttons["Send"].firstMatch.tap()
        let tip = app.buttons["Continue"]
        if tip.waitForExistence(timeout: 1) { tip.tap() }
        if app.keyboards.count > 0 { app.buttons["Hide Keyboard"].firstMatch.tap() }
        XCTAssertTrue(app.staticTexts["Sent. You'll see support's answer here."].waitForExistence(timeout: 30))
        settle()
        snap("01c-sent")
    }

    func testAnswer() throws {
        openReport()
        app.buttons["Your Reports"].firstMatch.tap()
        let first = app.cells.firstMatch.exists ? app.cells.firstMatch : app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Ejected the SD card")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        first.tap()
        settle(4)
        snap("02-answer")
    }

    /// About › Erase My Reports…: everything this device sent is deleted.
    func testErase() throws {
        let about = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "About")).firstMatch
        XCTAssertTrue(about.waitForExistence(timeout: 10))
        settle()
        snap("00-first")
        about.tap()
        XCTAssertTrue(app.navigationBars["About"].waitForExistence(timeout: 10))
        settle(2)
        // The row is below the fold, and lists make rows as they scroll in.
        app.swipeUp()
        let erase = app.buttons["Erase My Reports…"]
        XCTAssertTrue(erase.waitForExistence(timeout: 10), "no reports sent from this device")
        erase.tap()
        app.buttons["Erase"].firstMatch.tap()
        let done = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", "erased.")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 20))
        settle()
        snap("03-erased")
    }

    /// Demo airlock, then its ⋯ menu › Report a Problem….
    private func openReport() {
        let demo = app.buttons["Try a Demo Airlock"]
        if demo.waitForExistence(timeout: 10) {
            if !demo.isHittable { app.swipeUp() }
            demo.tap()
        }
        let row = app.staticTexts["Demo Airlock"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        settle(1)
        app.buttons["More"].firstMatch.tap()
        app.buttons["Report a Problem…"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Report a Problem"].waitForExistence(timeout: 10))
    }

    /// Hides the keyboard (the form dismisses it on scroll), and the
    /// keyboard's first-run tip if it's up.
    private func tapDone() {
        let tip = app.buttons["Continue"]
        if tip.waitForExistence(timeout: 1) { tip.tap() }
        app.buttons["Hide Keyboard"].firstMatch.tap()
    }

    private func settle(_ seconds: TimeInterval = 1.5) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func snap(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: outDir.appendingPathComponent("\(name).png"))
    }
}
