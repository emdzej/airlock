import XCTest

/// Report a Problem against the live ALIAS desk, on the demo airlock (no
/// real airlock, names or files on screen). Needs a build with a product
/// key. testReport sends a report; after support answers it, testAnswer
/// opens the thread. PNGs go to the runner's temporary directory,
/// airlock-screenshots/.
final class SupportTests: XCTestCase {
    private var app: XCUIApplication!
    private var outDir: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        outDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("airlock-screenshots")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchArguments += [
            "-launchedBefore", "NO",
            "-NSWindow Frame AirlockMainWindow", "120 120 1100 760 0 0 1920 1080 ",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        app.launch()
    }

    func testReport() throws {
        let window = openReport()
        let sheet = window.sheets.firstMatch
        let note = sheet.textViews.firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        note.click()
        note.typeText("Ejected the SD card, but the drive stays listed as mounted until I pull the reader out.")
        settle(3)
        snap(window, "01-report")
        try? app.debugDescription.write(to: outDir.appendingPathComponent("tree.txt"), atomically: true, encoding: .utf8)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "tree"
        tree.lifetime = .keepAlways
        add(tree)

        sheet.buttons["Black out parts"].firstMatch.click()
        let editor = window.sheets.element(boundBy: 0).sheets.firstMatch.exists
            ? window.sheets.element(boundBy: 0).sheets.firstMatch : window
        let canvas = editor.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ AND elementType != %d", "Black out what you don't want to send",
                                  XCUIElement.ElementType.staticText.rawValue)).firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        let from = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: 0.12))
        let to = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.22))
        from.press(forDuration: 0.1, thenDragTo: to)
        settle()
        snap(window, "01b-redact")
        editor.buttons["Done"].firstMatch.click()
        settle(1)

        sheet.buttons["Send"].firstMatch.click()
        XCTAssertTrue(sheet.staticTexts["Sent. You'll see support's answer here."].waitForExistence(timeout: 30))
        settle()
        snap(window, "01c-sent")
    }

    func testAnswer() throws {
        let window = openReport()
        let sheet = window.sheets.firstMatch
        sheet.buttons["Your Reports"].firstMatch.click()
        let first = sheet.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", "Ejected the SD card", "Ejected the SD card"))
            .firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        first.click()
        settle(4)
        snap(window, "02-answer")
    }

    /// The demo airlock, then Help › Report a Problem….
    private func openReport() -> XCUIElement {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let demo = window.buttons["Try a Demo Airlock"]
        if demo.waitForExistence(timeout: 10) { demo.click() }
        let row = window.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Demo Airlock")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()
        settle(2)
        let help = app.menuBars.menuBarItems["Help"]
        help.click()
        help.menus.menuItems["Report a Problem…"].click()
        XCTAssertTrue(window.sheets.firstMatch.waitForExistence(timeout: 10))
        settle(1)
        return window
    }

    private func settle(_ seconds: TimeInterval = 1.5) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func snap(_ element: XCUIElement, _ name: String) {
        let shot = element.screenshot()
        try? shot.pngRepresentation.write(to: outDir.appendingPathComponent("\(name).png"))
        // Also in the result bundle: xcresulttool export attachments.
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
