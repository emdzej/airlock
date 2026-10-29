import XCTest

/// Walks the app through the App Store screenshots. Expects a mock
/// airlock advertised as "Studio Airlock" with fixed drives and files;
/// writes PNGs to $SCREENSHOT_DIR (TEST_RUNNER_SCREENSHOT_DIR).
final class ScreenshotTests: XCTestCase {
    private let host = "Studio Airlock"
    private var app: XCUIApplication!
    private var outDir: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] ?? NSTemporaryDirectory()
        outDir = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        app = XCUIApplication()
        // The listing is en-US: US number and date formats, 12-hour clock.
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        // Landscape on iPad: the sidebar and the detail side by side.
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCUIDevice.shared.orientation = .landscapeLeft
        }
        app.launch()
    }

    func testScreenshots() throws {
        // On iPhone the host list comes first; on iPad it's the sidebar.
        let row = app.staticTexts[host].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "mock airlock not found; is it advertised?")
        row.tap()
        XCTAssertTrue(app.staticTexts["EOS_DIGITAL"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["SanDisk Extreme PRO"].firstMatch.waitForExistence(timeout: 10))
        settle()
        snap("01-overview")

        app.staticTexts["EOS_DIGITAL"].firstMatch.tap()
        open("DCIM")
        open("100CANON")
        XCTAssertTrue(app.staticTexts["IMG_4127.CR3"].firstMatch.waitForExistence(timeout: 10))
        settle()
        snap("02-files")
        for _ in 0..<3 { back() }

        app.staticTexts["SanDisk Extreme PRO"].firstMatch.tap()
        let partition = app.staticTexts["EOS_DIGITAL"].firstMatch
        XCTAssertTrue(partition.waitForExistence(timeout: 10))
        settle()
        snap("03-device")

        app.buttons["Actions for EOS_DIGITAL"].firstMatch.tap()
        app.buttons["Check Filesystem"].firstMatch.tap()
        app.buttons["Check"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["No errors found"].firstMatch.waitForExistence(timeout: 15))
        settle()
        snap("04-check")
        app.buttons["Close"].firstMatch.tap()

        app.buttons["Format…"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Format"].waitForExistence(timeout: 5))
        settle()
        snap("05-format")
    }

    private func open(_ name: String) {
        let item = app.staticTexts[name].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10), "\(name) not listed")
        item.tap()
    }

    private func back() {
        app.navigationBars.buttons.element(boundBy: 0).tap()
        settle(0.8)
    }

    /// Lets animations and the scroll-edge effects finish.
    private func settle(_ seconds: TimeInterval = 1.5) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func snap(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: outDir.appendingPathComponent("\(name).png"))
    }
}
