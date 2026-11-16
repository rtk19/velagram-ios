import XCTest

final class VelagramUITests: XCTestCase {
    @MainActor func testActualDeviceCatchupOpeningAndScrubbing() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VELAGRAM_LIVE_STREAMS"] == "1")
        let app = XCUIApplication()
        app.launchEnvironment["VELAGRAM_REAL_CATCHUP_UI"] = "1"
        app.launch()
        func revealControls() {
            if !app.sliders["player.timeline"].exists || !app.sliders["player.timeline"].isHittable {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
            }
        }
        func seconds() -> Double {
            let value = app.sliders["player.timeline"].value as? String ?? ""
            return value.split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) }
        }
        func assertPlaying(near target: Double? = nil) {
            let opening = app.staticTexts["Opening media…"]
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: opening)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 35), .completed)
            revealControls()
            let first = seconds()
            if let target { XCTAssertEqual(first, target, accuracy: 30) }
            Thread.sleep(forTimeInterval: 6)
            revealControls()
            XCTAssertGreaterThan(seconds(), first + 2)
            if let target { XCTAssertEqual(seconds(), target + 6, accuracy: 30) }
            XCTAssertFalse(opening.exists)
        }
        XCTAssertTrue(app.buttons["Open real catch-up"].waitForExistence(timeout: 15))
        app.buttons["Open real catch-up"].tap()
        XCTAssertTrue(app.sliders["player.timeline"].waitForExistence(timeout: 15))
        assertPlaying()
        let initial = XCTAttachment(screenshot: app.screenshot()); initial.name = "Real IPTV archive opened with saved resume"; initial.lifetime = .keepAlways; add(initial)
        for fraction: CGFloat in [0.44, 0.2] {
            revealControls()
            let previous = seconds()
            app.sliders["player.timeline"].adjust(toNormalizedSliderPosition: fraction)
            // XCTest's drag is approximate. Verify a substantial move in the
            // requested direction, then require playback to hold that selection.
            let selected = seconds()
            if fraction > 0.3 { XCTAssertGreaterThan(selected, previous + 1000) }
            else { XCTAssertLessThan(selected, previous - 1000) }
            assertPlaying(near: selected)
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Real IPTV after scrub \(fraction)"; shot.lifetime = .keepAlways; add(shot)
        }
        revealControls(); let saved = seconds(); app.buttons["Close player"].tap()
        XCTAssertTrue(app.buttons["Open real catch-up"].waitForExistence(timeout: 10))
        app.buttons["Open real catch-up"].tap()
        XCTAssertTrue(app.sliders["player.timeline"].waitForExistence(timeout: 10))
        assertPlaying(near: saved)
        let reopened = XCTAttachment(screenshot: app.screenshot()); reopened.name = "Real IPTV reopened at saved scrub position"; reopened.lifetime = .keepAlways; add(reopened)
    }
    @MainActor func testLiveSearchOpensChannelAndCatchupProgram() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "TelegramNativePlayback", withExtension: "mp4"))
        let app = XCUIApplication()
        app.launchEnvironment["VELAGRAM_IPTV_CATEGORY_FIXTURE"] = "1"
        app.launchEnvironment["VELAGRAM_IPTV_PLAYER_FIXTURE"] = "1"
        app.launchEnvironment["VELAGRAM_PLAYER_TEST_DIRECT"] = "1"
        app.launchEnvironment["VELAGRAM_PLAYER_TEST_FIXTURE"] = try Data(contentsOf: url).base64EncodedString()
        app.launch()
        let search = app.searchFields["Search channels and programs"]
        XCTAssertTrue(search.waitForExistence(timeout: 20)); search.tap(); search.typeText("Channel 000")
        let channel = app.buttons["live.search.channel.fixture:0"]
        XCTAssertTrue(channel.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Catch-up · 3 days"].exists)
        channel.tap()
        XCTAssertTrue(app.otherElements["Video"].waitForExistence(timeout: 10))
        let closeButtons = app.buttons.matching(NSPredicate(format: "label IN {'Close', 'Done', 'Close video'}"))
        if !closeButtons.allElementsBoundByIndex.contains(where: { $0.isHittable }) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.28)).tap()
        }
        let close = try XCTUnwrap(closeButtons.allElementsBoundByIndex.first(where: { $0.isHittable }))
        close.tap()
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap()
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Channel 000".count) + "Portland")
        let program = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'live.search.program.fixture:0'")).firstMatch
        XCTAssertTrue(program.waitForExistence(timeout: 10)); program.tap()
        XCTAssertTrue(app.navigationBars["Program details"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Portland highlights"].exists)
    }
    @MainActor func testSelectMultipleChannelsAndMoveTogether() {
        let app = XCUIApplication(); app.launchEnvironment["VELAGRAM_IPTV_CATEGORY_FIXTURE"] = "1"; app.launch()
        XCTAssertTrue(app.staticTexts["News"].waitForExistence(timeout: 20)); app.staticTexts["News"].tap()
        app.navigationBars.buttons.matching(identifier: "More").firstMatch.tap()
        app.buttons["Edit category"].tap()
        XCTAssertTrue(app.navigationBars["Edit category"].waitForExistence(timeout: 5))
        app.buttons["Select multiple channels"].tap()
        app.buttons["Select Channel 000"].tap(); app.buttons["Select Channel 002"].tap()
        XCTAssertTrue(app.staticTexts["2 selected"].exists)
        app.buttons["Send to bottom"].tap()
        XCTAssertTrue(app.switches["Channel 004"].isHittable)
        app.buttons["Send to top"].tap()
        XCTAssertTrue(app.switches["Channel 000"].isHittable)
        XCTAssertTrue(app.switches["Channel 002"].isHittable)
    }

    @MainActor func testGuideSearchZoomAndLandscape() {
        let app = XCUIApplication()
        app.launchEnvironment["VELAGRAM_IPTV_GUIDE_FIXTURE"] = "1"
        app.launch()
        XCTAssertTrue(app.navigationBars["Program guide"].waitForExistence(timeout: 20))
        app.swipeDown()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Channel 000")
        XCTAssertTrue(app.staticTexts["1 channels"].waitForExistence(timeout: 10))
        app.keyboards.buttons["Search"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let now = app.buttons["Now"]
        XCTAssertTrue(now.waitForExistence(timeout: 10))
        let timeline = app.scrollViews["epg.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))
        timeline.pinch(withScale: 2, velocity: 1)
        XCTAssertNotEqual(timeline.value as? String, "Zoom 100 percent")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Channel 000'")).firstMatch.isHittable)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Filtered landscape guide after pinch"
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor func testLiveCategoriesAndBulkVisibilityEditor() {
        let app = XCUIApplication()
        app.launchEnvironment["VELAGRAM_IPTV_CATEGORY_FIXTURE"] = "1"
        app.launch()
        XCTAssertTrue(app.staticTexts["News"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.staticTexts["Channel 000"].exists)
        app.staticTexts["News"].tap()
        XCTAssertTrue(app.staticTexts["Channel 000"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["live.options"].tap(); app.buttons["Edit categories"].tap()
        XCTAssertTrue(app.navigationBars["Edit categories"].waitForExistence(timeout: 5))
        let search = app.textFields["Search categories"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("News")
        app.buttons["Hide all"].tap()
        XCTAssertEqual(app.switches["Hide News"].value as? String, "1")
        app.buttons["Flip choices"].tap()
        XCTAssertEqual(app.switches["Hide News"].value as? String, "0")
        app.buttons["Hide all"].tap(); app.navigationBars.buttons["Done"].tap()
        XCTAssertFalse(app.staticTexts["News"].exists)
        app.buttons["live.options"].tap(); app.buttons["Edit categories"].tap()
        app.buttons["Show all"].tap(); app.navigationBars.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["News"].waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Live category navigation"; shot.lifetime = .keepAlways; add(shot)
    }
    @MainActor func testLiveInfoTracksNativeControls() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "TelegramNativePlayback", withExtension: "mp4"))
        let app = XCUIApplication()
        app.launchEnvironment["VELAGRAM_PLAYER_TEST_FIXTURE"] = try Data(contentsOf: url).base64EncodedString()
        app.launchEnvironment["VELAGRAM_PLAYER_TEST_DIRECT"] = "1"
        app.launchEnvironment["VELAGRAM_IPTV_PLAYER_FIXTURE"] = "1"
        app.launch()
        let epg = app.buttons["live.epg"]
        if !epg.exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.28)).tap() }
        XCTAssertTrue(epg.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["live.close"].exists)
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: epg)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 12), .completed)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.28)).tap()
        XCTAssertTrue(epg.waitForExistence(timeout: 5))
        let nativeButtons = XCTAttachment(string: app.debugDescription); nativeButtons.name = "Native controls hierarchy"; nativeButtons.lifetime = .keepAlways; add(nativeButtons)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Synchronized native live controls"; shot.lifetime = .keepAlways; add(shot)
    }

    @MainActor func testOfflineLibraryShowsDownloadedAndCachedShelves() {
        let app = XCUIApplication(); app.launchEnvironment["VELAGRAM_OFFLINE_LIBRARY_FIXTURE"] = "1"; app.launch()
        XCTAssertTrue(app.navigationBars["Downloads"].waitForExistence(timeout: 10))
        let title = app.buttons["downloads.title.tmdb:tv:-901"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "downloads.title.tmdb:tv:-901").count, 1)
        XCTAssertFalse(app.staticTexts["Continue Watching"].exists)
        XCTAssertFalse(app.staticTexts["S01E01 • 00:05:00"].exists)
        XCTAssertTrue(app.staticTexts["Downloading S01E02 · Episode 2"].exists)
        XCTAssertTrue(app.staticTexts["2 episodes"].exists)
        let root = XCTAttachment(screenshot: app.screenshot()); root.name = "Offline title navigator"; root.lifetime = .keepAlways; add(root)
        title.tap()
        let first = app.buttons["downloads.episode.tmdb:tv:-901:s1e1"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["downloads.episode.tmdb:tv:-901:s1e2"].exists)
        let episodes = XCTAttachment(screenshot: app.screenshot()); episodes.name = "Offline episode navigator"; episodes.lifetime = .keepAlways; add(episodes)
        first.tap()
        XCTAssertTrue(app.staticTexts["Sources · 2"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts.matching(identifier: "The.Offline.Collection.S01E01.1080p.mp4").count, 1)
        XCTAssertTrue(app.staticTexts["Downloaded"].exists)
        XCTAssertTrue(app.buttons["Keep download"].exists)
        let sources = XCTAttachment(screenshot: app.screenshot()); sources.name = "Deduplicated offline releases"; sources.lifetime = .keepAlways; add(sources)
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["downloads.episode.tmdb:tv:-901:s1e2"].tap()
        XCTAssertTrue(app.staticTexts["25%"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["128 MB of 512 MB"].exists)
        XCTAssertTrue(app.buttons["Cancel download"].exists)
        app.buttons["Cancel download"].tap()
        XCTAssertTrue(app.buttons["Keep downloading"].waitForExistence(timeout: 3))
        app.buttons["Keep downloading"].tap()
        XCTAssertTrue(app.staticTexts["25%"].exists)
        let transfer = XCTAttachment(screenshot: app.screenshot()); transfer.name = "Source transfer metrics"; transfer.lifetime = .keepAlways; add(transfer)
    }

    @MainActor func testHomeOpensUnifiedOfflineLibrary() {
        let app = XCUIApplication(); app.launch()
        let downloads = app.buttons["home.downloads"].firstMatch
        XCTAssertTrue(downloads.waitForExistence(timeout: 45))
        downloads.tap()
        XCTAssertTrue(app.navigationBars["Downloads"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.segmentedControls.buttons["Cached"].exists)
        app.segmentedControls.buttons["Cached"].tap()
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Unified offline library"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.45)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.45)))
        XCTAssertTrue(downloads.waitForExistence(timeout: 5))
    }

    @MainActor func testGuideNowReturnsFromHistoryAndShowsFullDateRange() throws {
        let app = XCUIApplication()
        app.launchEnvironment["VELAGRAM_IPTV_GUIDE_FIXTURE"] = "1"
        app.launchEnvironment["VELAGRAM_IPTV_DATE_RANGE_FIXTURE"] = "1"
        app.launch()
        let search = app.searchFields["Find a channel"]
        XCTAssertTrue(search.waitForExistence(timeout: 20))
        search.tap(); search.typeText("Channel 000\n")
        let yesterday = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Yesterday'")).firstMatch
        XCTAssertTrue(yesterday.waitForExistence(timeout: 20)); yesterday.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Guide day -1'")).firstMatch.waitForExistence(timeout: 10))
        app.buttons["Now"].tap()
        let today = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Today'")).firstMatch
        XCTAssertTrue(today.waitForExistence(timeout: 5))
        XCTAssertEqual(today.value as? String, "Selected")
        let stripY = today.frame.midY
        let left = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 60, dy: stripY))
        let right = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.width - 60, dy: stripY))
        let start = Calendar.current.startOfDay(for: .now)
        for offset in [-14, 15] {
            let date = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: offset, to: start))
            let button = app.buttons["epg.day." + String(Int(date.timeIntervalSince1970))]
            for _ in 0..<12 {
                if button.exists {
                    let frame = button.frame
                    if frame.width > 0 && frame.minX >= 0 && frame.maxX <= app.frame.width { break }
                }
                if offset < 0 { left.press(forDuration: 0.05, thenDragTo: right) }
                else { right.press(forDuration: 0.05, thenDragTo: left) }
            }
            XCTAssertTrue(button.exists)
            let frame = button.frame
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertGreaterThanOrEqual(frame.minX, 0)
            XCTAssertLessThanOrEqual(frame.maxX, app.frame.width)
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: stripY)).tap()
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Guide day \(offset)")).firstMatch.waitForExistence(timeout: 10))
            app.buttons["Now"].tap()
            XCTAssertEqual(today.value as? String, "Selected")
        }
    }

    @MainActor func testLargeIPTVGuideScrollsAndOpensProgram() {
        let app = XCUIApplication()
        app.launchEnvironment["VELAGRAM_IPTV_GUIDE_FIXTURE"] = "1"
        app.launch()
        // Keep this scrolling fixture scoped to its imported channels; the full
        // guide now also retains bundled channels without schedule data.
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 20))
        search.tap(); search.typeText("Channel ")
        app.keyboards.buttons["Search"].tap()
        XCTAssertTrue(app.staticTexts["727 channels"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Channel 000'")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Channel 000'")).firstMatch.isHittable)
        let initial = XCTAttachment(screenshot: app.screenshot()); initial.name = "727 channel timeline"; initial.lifetime = .keepAlways; add(initial)
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.7))
        from.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.4)))
        let right = app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        right.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        XCTAssertTrue(app.buttons["Now"].exists)
        app.buttons["Now"].tap()
        let final = XCTAttachment(screenshot: app.screenshot()); final.name = "Timeline after two-axis scrolling"; final.lifetime = .keepAlways; add(final)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.4)).tap()
        XCTAssertTrue(app.navigationBars["Program details"].waitForExistence(timeout: 10))
    }

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
        app.navigationBars.buttons.firstMatch.tap()
    }
    @MainActor func testLiveSourcesMenuAndHorizontalSwipes() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "TelegramNativePlayback", withExtension: "mp4"))
        let app = XCUIApplication()
        app.launchEnvironment["VELAGRAM_PLAYER_TEST_FIXTURE"] = try Data(contentsOf: url).base64EncodedString()
        app.launchEnvironment["VELAGRAM_PLAYER_TEST_DIRECT"] = "1"
        app.launchEnvironment["VELAGRAM_IPTV_PLAYER_FIXTURE"] = "1"
        app.launchEnvironment["VELAGRAM_IPTV_SOURCES_FIXTURE"] = "1"
        app.launch()
        let menu = app.buttons["live.changeSource"]
        func revealControls() {
            if !menu.isHittable { app.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.28)).tap() }
            XCTAssertTrue(menu.waitForExistence(timeout: 10))
        }
        XCTAssertTrue(app.otherElements["Video"].waitForExistence(timeout: 15))
        revealControls()
        XCTAssertEqual(menu.value as? String, "News One")
        menu.tap()
        app.buttons["News One - (גיבוי 2)"].tap()
        revealControls()
        XCTAssertEqual(menu.value as? String, "News One - (גיבוי 2)")
        XCTAssertEqual(app.staticTexts["live.sourceName"].label, "גיבוי 2")
        let left = app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.7))
        let right = app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.7))
        left.press(forDuration: 0.05, thenDragTo: right)
        revealControls()
        XCTAssertEqual(menu.value as? String, "News One - (גיבוי 3)")
        XCTAssertEqual(app.staticTexts["live.sourceName"].label, "גיבוי 3")
        right.press(forDuration: 0.05, thenDragTo: left)
        revealControls()
        XCTAssertEqual(menu.value as? String, "News One - (גיבוי 2)")
        XCTAssertEqual(app.staticTexts["live.sourceName"].label, "גיבוי 2")
        XCTAssertTrue(app.staticTexts["Morning news"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Combined channel source controls"; shot.lifetime = .keepAlways; add(shot)
    }

    @MainActor func testLiveChannelSwipesAndFocusedEPG() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "TelegramNativePlayback", withExtension: "mp4"))
        let app = XCUIApplication()
        app.launchEnvironment["VELAGRAM_PLAYER_TEST_FIXTURE"] = try Data(contentsOf: url).base64EncodedString()
        app.launchEnvironment["VELAGRAM_PLAYER_TEST_DIRECT"] = "1"
        app.launchEnvironment["VELAGRAM_IPTV_PLAYER_FIXTURE"] = "1"
        app.launch()
        if !app.buttons["live.epg"].exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.28)).tap() }
        XCTAssertTrue(app.staticTexts["Morning news"].waitForExistence(timeout: 15))
        let low = app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.7))
        let high = app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.3))
        low.press(forDuration: 0.05, thenDragTo: high)
        if !app.buttons["live.epg"].exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.28)).tap() }
        XCTAssertTrue(app.staticTexts["News Two"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Sports roundup"].exists)
        high.press(forDuration: 0.05, thenDragTo: low)
        if !app.buttons["live.epg"].exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.28)).tap() }
        XCTAssertTrue(app.staticTexts["News One"].waitForExistence(timeout: 10))
        if !app.buttons["live.epg"].exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap() }
        XCTAssertTrue(app.buttons["live.epg"].waitForExistence(timeout: 5))
        app.buttons["live.epg"].tap()
        XCTAssertTrue(app.otherElements["epg.onNow"].firstMatch.waitForExistence(timeout: 5) || app.staticTexts["On now"].isHittable)
        XCTAssertTrue(app.staticTexts["On now"].isHittable)
        XCTAssertTrue(app.navigationBars["News One"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Sports roundup"].exists)
        app.buttons["Full EPG"].tap()
        XCTAssertTrue(app.navigationBars["Program guide"].waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Full guide from live player"; shot.lifetime = .keepAlways; add(shot)
        let otherChannel = app.buttons.matching(NSPredicate(format: "label CONTAINS 'News Two'")).firstMatch
        XCTAssertTrue(otherChannel.waitForExistence(timeout: 5)); otherChannel.tap()
        if !app.buttons["live.epg"].exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.28)).tap() }
        XCTAssertTrue(app.staticTexts["Sports roundup"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["live.epg"].exists)
        XCTAssertFalse(app.navigationBars["Program guide"].exists)
    }

    @MainActor func testLivePlayerNativeCloseDismissesPresentation() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "TelegramNativePlayback", withExtension: "mp4"))
        let app = XCUIApplication()
        app.launchEnvironment["VELAGRAM_PLAYER_TEST_FIXTURE"] = try Data(contentsOf: url).base64EncodedString()
        app.launchEnvironment["VELAGRAM_PLAYER_TEST_DIRECT"] = "1"
        app.launch()
        let close = app.buttons.matching(NSPredicate(format: "label IN {'Close', 'Done', 'Close video'}")).firstMatch
        if !close.exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.28)).tap() }
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
