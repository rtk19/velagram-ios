import XCTest

final class VelagramUITests: XCTestCase {
    @MainActor func testCacheSettingsOverviewAndSafeCleanupConfirmation() {
        let app = XCUIApplication(); app.launch()
        let more = app.tabBars.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 30)); more.tap()
        let settings = app.staticTexts["Settings & backup"]
        for _ in 0..<3 where !settings.isHittable { app.swipeUp() }
        XCTAssertTrue(settings.waitForExistence(timeout: 10)); settings.tap()
        let cache = app.buttons["settings.cache"]
        XCTAssertTrue(cache.waitForExistence(timeout: 10)); cache.tap()
        XCTAssertTrue(app.navigationBars["Cache & Storage"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["cache.total"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Video & Telegram files"].exists)
        let overview = XCTAttachment(screenshot: app.screenshot()); overview.name = "Cache overview"; overview.lifetime = .keepAlways; add(overview)
        let clear = app.buttons["cache.clear.all"]
        for _ in 0..<4 where !clear.isHittable { app.swipeUp() }
        XCTAssertTrue(clear.waitForExistence(timeout: 10)); clear.tap()
        if app.buttons["Cancel"].waitForExistence(timeout: 2) { app.buttons["Cancel"].tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.65)).tap() }
        XCTAssertTrue(app.navigationBars["Cache & Storage"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Cache management"; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    @MainActor func testLiveAndMoreNavigation() {
        let app = XCUIApplication()
        app.launch()
        let live = app.tabBars.buttons["Live"]
        XCTAssertTrue(live.waitForExistence(timeout: 15))
        XCTAssertTrue(NSPredicate(format: "hittable == true").evaluate(with: live) || XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: live)], timeout: 15) == .completed)
        live.tap()
        XCTAssertTrue(app.staticTexts["Live television"].waitForExistence(timeout: 10))
        let liveScreenshot = XCTAttachment(screenshot: app.screenshot())
        liveScreenshot.name = "Velagram Live TV"
        liveScreenshot.lifetime = .keepAlways
        add(liveScreenshot)
        app.tabBars.buttons["More"].tap()
        XCTAssertTrue(app.staticTexts["Jellyfin & Emby"].waitForExistence(timeout: 5))
        app.staticTexts["Files & direct streams"].tap()
        XCTAssertTrue(app.buttons["Play stream"].waitForExistence(timeout: 5))
        let filesScreenshot = XCTAttachment(screenshot: app.screenshot())
        filesScreenshot.name = "Velagram Files"
        filesScreenshot.lifetime = .keepAlways
        add(filesScreenshot)
    }
    @MainActor func testTelegramAccountRemainsAvailableUnderMore() {
        let app = XCUIApplication()
        app.launch()
        let more = app.tabBars.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 30))
        more.tap()
        app.staticTexts["Telegram account & files"].tap()
        XCTAssertTrue(app.navigationBars["Telegram"].waitForExistence(timeout: 15))
    }

    @MainActor func testCatalogOpensCombinedSourcePicker() throws {
        let app = XCUIApplication()
        app.launch()
        let candidates = app.buttons.matching(identifier: "View Details")
        XCTAssertTrue(candidates.firstMatch.waitForExistence(timeout: 45))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            candidates.allElementsBoundByIndex.contains { $0.isHittable }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
        let details = try XCTUnwrap(candidates.allElementsBoundByIndex.first { $0.isHittable })
        details.tap()
        let play = app.buttons["catalog.chooseSource"]
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: play)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 30), .completed)
        play.tap()
        XCTAssertTrue(app.navigationBars["Sources"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Choose a source to play"].exists)
        XCTAssertTrue(app.segmentedControls.buttons["Telegram"].exists)
        XCTAssertTrue(app.segmentedControls.buttons["Web"].exists)
        app.buttons["Done"].tap()
    }
    @MainActor func testLivePlayerNativeCloseDismissesPresentation() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "TelegramNativePlayback", withExtension: "mp4"))
        let app = XCUIApplication()
        app.launchEnvironment["VELAGRAM_PLAYER_TEST_FIXTURE"] = try Data(contentsOf: url).base64EncodedString()
        app.launchEnvironment["VELAGRAM_PLAYER_TEST_DIRECT"] = "1"
        app.launch()
        let close = app.buttons["live.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 15))
        close.tap()
        XCTAssertTrue(app.staticTexts["Playback closed"].waitForExistence(timeout: 5))
    }

    @MainActor func testNativePlayerSettingsAutoHideAndReturnOnTap() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "TelegramNativePlayback", withExtension: "mp4"))
        let app = XCUIApplication()
        app.launchEnvironment["VELAGRAM_PLAYER_TEST_FIXTURE"] = try Data(contentsOf: url).base64EncodedString()
        app.launchEnvironment["VELAGRAM_PLAYER_TEST_CONTAINER"] = "mp4"
        app.launch()
        let settings = app.buttons["player.settings"]
        if !settings.isHittable { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap() }
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["player.playPause"].exists)
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == false"), object: settings)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 10), .completed)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: settings)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Native player Vela settings control"; screenshot.lifetime = .keepAlways; add(screenshot)
        settings.tap()
        XCTAssertTrue(app.navigationBars["Playback settings"].waitForExistence(timeout: 5))
        let skip = app.sliders["settings.doubleTapSkip"]
        for _ in 0..<6 where !skip.exists { app.swipeUp() }
        XCTAssertTrue(skip.exists)
    }

    @MainActor func testModernTelegramPlayerControlsAndGestures() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "TelegramInteraction", withExtension: "mkv"))
        let app = XCUIApplication()
        app.launchEnvironment["VELAGRAM_PLAYER_TEST_FIXTURE"] = try Data(contentsOf: url).base64EncodedString()
        app.launch()
        let playPause = app.buttons["player.playPause"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 15))
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Pause'"), object: playPause)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 10), .completed)
        let video = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        video.doubleTap()
        let paused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Play'"), object: playPause)
        XCTAssertEqual(XCTWaiter.wait(for: [paused], timeout: 5), .completed)
        playPause.doubleTap()
        let resumed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Pause'"), object: playPause)
        XCTAssertEqual(XCTWaiter.wait(for: [resumed], timeout: 5), .completed)
        playPause.doubleTap()
        let pausedAgain = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Play'"), object: playPause)
        XCTAssertEqual(XCTWaiter.wait(for: [pausedAgain], timeout: 5), .completed)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.35)).doubleTap()
        let advanced = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value MATCHES %@", "0:(1[5-9]|2[0-9])"), object: app.sliders["player.timeline"])
        XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 5), .completed)
        app.buttons["player.settings"].tap()
        XCTAssertTrue(app.navigationBars["Playback settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Open subtitle file…"].exists)
        app.buttons["Done"].tap()
        app.buttons["player.subtitles"].tap()
        XCTAssertTrue(app.buttons["Find or import subtitles…"].waitForExistence(timeout: 5))
        app.buttons["Find or import subtitles…"].tap()
        XCTAssertTrue(app.navigationBars["Subtitles"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Audio delay"].exists)
        app.buttons["Done"].tap()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Velagram modern player — generated media"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

}
