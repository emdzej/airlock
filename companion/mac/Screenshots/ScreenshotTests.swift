import XCTest

/// Mac App Store screenshots. Expects a mock airlock advertised as
/// "Studio Airlock" with fixed drives and files; writes PNGs to the
/// (sandboxed) runner's temporary directory, airlock-screenshots/.
final class ScreenshotTests: XCTestCase {
    private let host = "Studio Airlock"
    private var app: XCUIApplication!
    private var outDir: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        // The runner is sandboxed: write into its own temporary
        // directory; screenshots.sh copies the files out.
        outDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("airlock-screenshots")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchArguments += [
            // Open the window as on first launch, at a fixed size.
            "-launchedBefore", "NO",
            "-NSWindow Frame AirlockMainWindow", "120 120 1280 800 0 0 1920 1080 ",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        app.launch()
    }

    func testScreenshots() throws {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        // Wait until it's live, not just remembered from an earlier run.
        let row = item(window, "\(host), 3 drives")
        if !row.waitForExistence(timeout: 30) {
            try? app.debugDescription.write(to: outDir.appendingPathComponent("tree.txt"), atomically: true, encoding: .utf8)
            XCTFail("mock airlock not found; is it advertised?")
            return
        }
        row.click()
        if !item(window, "SanDisk Extreme PRO").waitForExistence(timeout: 10) {
            try? app.debugDescription.write(to: outDir.appendingPathComponent("tree.txt"), atomically: true, encoding: .utf8)
            XCTFail("devices not listed"); return
        }
        settle()
        snap(window, "01-overview")

        // The menu-bar menu: mount and open drives without the window.
        let status = app.statusItems.firstMatch
        let menu = status.menus.firstMatch
        // The first click after launch sometimes only activates the app;
        // the element also exists before the menu is on screen.
        for _ in 0..<3 where menu.frame.width == 0 {
            status.click()
            settle(1.5)
        }
        XCTAssertGreaterThan(menu.frame.width, 0, "menu-bar menu didn't open")
        settle(0.8)
        snap(menu, "06-menu")
        app.typeKey(.escape, modifierFlags: [])

        item(window, "EOS_DIGITAL").click()
        open(window, "DCIM")
        open(window, "100CANON")
        XCTAssertTrue(item(window, "IMG_4127.CR3").waitForExistence(timeout: 10))
        settle()
        snap(window, "02-files")
        for _ in 0..<3 { back(window) }

        item(window, "SanDisk Extreme PRO").click()
        let partition = item(window, "EOS_DIGITAL")
        XCTAssertTrue(partition.waitForExistence(timeout: 10))
        settle()
        snap(window, "03-device")

        // The partition row's … menu (the only menu button in the lists).
        window.outlines.menuButtons.firstMatch.click()
        app.menuItems["Check Filesystem"].firstMatch.click()
        let sheet = window.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        sheet.buttons["Check"].firstMatch.click()
        XCTAssertTrue(item(sheet, "No errors found").waitForExistence(timeout: 15))
        settle()
        snap(window, "04-check")
        sheet.buttons["Close"].firstMatch.click()

        window.buttons["Format…"].firstMatch.click()
        XCTAssertTrue(window.sheets.firstMatch.waitForExistence(timeout: 5))
        settle()
        snap(window, "05-format")
        window.sheets.firstMatch.buttons["Cancel"].firstMatch.click()
    }

    private func open(_ window: XCUIElement, _ name: String) {
        let row = item(window, name)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "\(name) not listed")
        row.click()
    }

    /// SwiftUI rows on the Mac merge their texts into one label
    /// ("Studio Airlock, 3 drives"): match on the start.
    private func item(_ root: XCUIElement, _ text: String) -> XCUIElement {
        root.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", text, text))
            .firstMatch
    }

    private func back(_ window: XCUIElement) {
        window.buttons["Back"].firstMatch.click()
        settle(0.8)
    }

    private func settle(_ seconds: TimeInterval = 1.5) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func snap(_ element: XCUIElement, _ name: String) {
        let png = element.screenshot().pngRepresentation
        try? png.write(to: outDir.appendingPathComponent("\(name).png"))
    }
}
