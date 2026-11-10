import XCTest

final class ViewerUITests: XCTestCase {
    private func save(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        guard let folder = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let tag = ProcessInfo.processInfo.environment["SNAPSHOT_TAG"].map { "-" + $0 } ?? ""
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(device)\(tag)-\(name).png"))
    }

    private func fixture(named name: String) throws -> String {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "example", withExtension: "html"), "The example page is bundled with the tests")
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: copy)
        return copy.path
    }

    /// A self-contained single-file web app opened the way a picked file is: it must render and run.
    func testExamplePageOpensAndRuns() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-open", try fixture(named: "notes.html")]
        app.launch()
        let loaded = app.webViews.staticTexts["Notes"].waitForExistence(timeout: 40)
        sleep(2)
        save("6-example-page")
        if !loaded { print("HIERARCHY\n" + app.debugDescription) }
        XCTAssertTrue(loaded, "The example page shows its heading")
        XCTAssertFalse(app.otherElements["failure"].exists, "No load failure is shown")
        XCTAssertTrue(app.buttons["addressPill"].label.contains("notes.html"), "The tab is on the opened file: \(app.buttons["addressPill"].label)")
        // The page's own script and storage work: add a note and see it listed.
        let field = app.webViews.textFields.firstMatch
        if field.waitForExistence(timeout: 5) {
            field.tap(); field.typeText("milk\n")
            XCTAssertTrue(app.webViews.staticTexts["milk"].waitForExistence(timeout: 10), "The page's script ran and saved the note")
        }
    }

    /// The same file chosen by hand in the system Files picker.
    func testPickingAFileInTheFilesPicker() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "The Files picker is laid out differently on iPad; this drives the iPhone layout")
        let app = XCUIApplication()
        app.launchArguments = ["-seed", try fixture(named: "picked-notes.html")]
        app.launch()
        XCTAssertTrue(app.buttons["openFiles"].waitForExistence(timeout: 30) || app.buttons["openMenu"].exists)
        if !app.buttons["openFiles"].exists {
            app.buttons["tabsButton"].tap(); app.buttons["newTab"].tap()
            XCTAssertTrue(app.buttons["openFiles"].waitForExistence(timeout: 10))
        }
        app.buttons["openFiles"].tap()
        sleep(3)
        save("7-picker")
        // Navigate to On My iPhone → HTML Viewer, wherever the picker starts.
        let file = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'picked-notes'")).firstMatch
        for label in ["Browse", "On My iPhone", "HTML Viewer"] where !file.exists {
            let named = NSPredicate(format: "label == %@", label)
            let target = label == "Browse" ? app.buttons.matching(named).firstMatch : app.staticTexts.matching(named).firstMatch
            if target.waitForExistence(timeout: 5) { target.tap(); sleep(2) }
        }
        save("8-picker-folder")
        if !file.waitForExistence(timeout: 10) { print("HIERARCHY\n" + app.debugDescription) }
        XCTAssertTrue(file.exists, "The seeded file is visible in the picker")
        // The picker keeps off-screen copies of the same label (its Recents tab); tap the one actually on screen.
        let candidates = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'picked-notes'")).allElementsBoundByIndex
        print("CANDIDATES " + candidates.map { "\($0.frame) hittable=\($0.isHittable)" }.joined(separator: " | "))
        let visible = try XCTUnwrap(candidates.first { $0.isHittable && $0.frame.minY > 100 && $0.frame.maxY < 800 }, "A tappable file entry")
        visible.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -1.2)).tap()
        let open = app.buttons["Open"]
        if open.waitForExistence(timeout: 5) { open.tap() }
        let loaded = app.webViews.staticTexts["Notes"].waitForExistence(timeout: 40)
        save("9-picked-page")
        if !loaded { print("HIERARCHY\n" + app.debugDescription) }
        XCTAssertTrue(loaded, "The picked file opens in a tab")
    }

    /// The whole flow on a running app: sample site loads with every check passing, a link opens a second tab,
    /// the tab overview shows both, and both come back after the app is quit and reopened.
    func testSampleTabsAndRestore() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-sample"]
        app.launch()
        XCTAssertTrue(app.webViews.staticTexts["It works"].waitForExistence(timeout: 40), "The sample page loads")
        XCTAssertTrue(app.webViews.staticTexts["All 5 checks passed"].waitForExistence(timeout: 20), "Styles, image, module, fetch and storage all work")
        save("1-sample-page")

        app.webViews.links["in a new tab"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Second page"].waitForExistence(timeout: 20), "target=_blank opens a new tab")
        save("2-second-page")

        app.buttons["tabsButton"].tap()
        XCTAssertTrue(app.buttons["tabsDone"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Sample page"].exists && app.staticTexts["Second page"].exists, "Both tabs are in the overview")
        save("3-tab-overview")
        app.buttons["tabsDone"].tap()

        app.terminate()
        let relaunched = XCUIApplication()
        relaunched.launch()
        XCTAssertTrue(relaunched.webViews.staticTexts["Second page"].waitForExistence(timeout: 40), "Open tabs are restored after a relaunch")
        relaunched.webViews.links["Back to the first page"].tap()
        XCTAssertTrue(relaunched.webViews.staticTexts["All 5 checks passed"].waitForExistence(timeout: 20), "Links between local pages work")
        save("4-restored")

        relaunched.buttons["tabsButton"].tap()
        relaunched.buttons["newTab"].tap()
        XCTAssertTrue(relaunched.buttons["openFiles"].waitForExistence(timeout: 10), "A new tab shows the start page")
        save("5-start-page")
    }
}
