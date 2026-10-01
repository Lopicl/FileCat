import XCTest

/// End-to-end smoke tests. Each test starts from a fresh, known set of files
/// (see `UITestSupport` in the app target).
final class FileCatUITests: XCTestCase {
    private var app: XCUIApplication!

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-FileCatUITestReset", "YES"]
        app.launch()
        XCTAssertTrue(app.staticTexts["hello.txt"].waitForExistence(timeout: 10))
    }

    // MARK: File management

    func testCreateRenameAndDeleteFolder() {
        openAddMenu("Create Folder")
        let alert = app.alerts["New Folder"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        replaceText(in: alert.textFields.firstMatch, with: "Projects")
        // Right after launch the keyboard can still be settling and swallow the first tap.
        alert.buttons["Create"].tap()
        if !waitForDisappearance(alert, timeout: 2) { alert.buttons["Create"].tap() }
        XCTAssertTrue(app.staticTexts["Projects"].waitForExistence(timeout: 3))

        app.staticTexts["Projects"].press(forDuration: 1.2)
        app.buttons["Rename"].tap()
        let rename = app.alerts["Rename"]
        XCTAssertTrue(rename.waitForExistence(timeout: 3))
        replaceText(in: rename.textFields.firstMatch, with: "Archive")
        rename.buttons["Rename"].tap()
        if !waitForDisappearance(rename, timeout: 2) { rename.buttons["Rename"].tap() }
        XCTAssertTrue(app.staticTexts["Archive"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Projects"].exists)

        app.staticTexts["Archive"].swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        let confirm = app.alerts.firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.buttons["Delete"].tap()
        XCTAssertTrue(waitForDisappearance(app.staticTexts["Archive"]))
    }

    func testDuplicateFromContextMenu() {
        app.staticTexts["hello.txt"].press(forDuration: 1.2)
        app.buttons["Duplicate"].tap()
        XCTAssertTrue(app.staticTexts["hello 2.txt"].waitForExistence(timeout: 3))
    }

    func testMoveFileIntoFolder() {
        app.staticTexts["hello.txt"].press(forDuration: 1.2)
        app.buttons["Move"].tap()
        let sheet = app.navigationBars["Move “hello.txt”"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 3))
        // The picker's row, not the tab of the same name behind the sheet.
        app.cells.staticTexts["Local Storage"].firstMatch.tap()
        let pickerDocs = app.collectionViews["folderPicker"].staticTexts["Docs"]
        XCTAssertTrue(pickerDocs.waitForExistence(timeout: 3))
        pickerDocs.tap()
        XCTAssertTrue(app.navigationBars["Docs"].waitForExistence(timeout: 3))
        app.navigationBars["Docs"].buttons["Move"].tap()

        XCTAssertTrue(waitForDisappearance(app.staticTexts["hello.txt"]))
        app.staticTexts["Docs"].tap()
        XCTAssertTrue(app.staticTexts["hello.txt"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["nested.txt"].exists)
    }

    func testSearchFindsNestedFiles() {
        let search = openSearch()
        if UIDevice.current.userInterfaceIdiom == .phone {
            XCTAssertTrue(waitForDisappearance(tabButton("tags")), "Searching hides the tab bar")
        }
        search.typeText("nested")
        XCTAssertTrue(app.staticTexts["nested.txt"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["in Docs"].exists)
        XCTAssertFalse(app.staticTexts["hello.txt"].exists)

        // The X inside the pill closes search and brings everything back.
        app.buttons["closeSearch"].tap()
        XCTAssertTrue(waitForDisappearance(search))
        XCTAssertTrue(app.staticTexts["hello.txt"].waitForExistence(timeout: 3))
        XCTAssertTrue(tabButton("tags").waitForExistence(timeout: 3), "Tab bar is back")
    }

    func testMultipleSelection() {
        openMoreMenu("Select")
        app.staticTexts["hello.txt"].tap()
        app.staticTexts["notes.md"].tap()
        XCTAssertTrue(app.staticTexts["2 Selected"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Share"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["More"].waitForExistence(timeout: 3))
    }

    func testFileCatLinksOpenAndRevealFiles() {
        // What a companion app does for "Show in FileCat".
        openTab("settings")
        app.open(URL(string: "filecat://open?path=notes.md")!)
        XCTAssertTrue(app.staticTexts["Project Notes"].waitForExistence(timeout: 5), "The link opens the file in Local Storage")

        app.open(URL(string: "filecat://reveal?path=Docs/nested.txt")!)
        XCTAssertTrue(app.navigationBars["Docs"].waitForExistence(timeout: 5), "Reveal shows the containing folder")
        XCTAssertTrue(app.staticTexts["nested.txt"].exists)
    }

    func testCloudOnlyFilesAreListed() {
        app.staticTexts["Docs"].tap()
        XCTAssertTrue(app.staticTexts["nested.txt"].waitForExistence(timeout: 3))
        // iCloud's hidden ".Cloud Report.pdf.icloud" stand-in shows as the real file, with its size.
        let cloudFile = app.staticTexts["Cloud Report.pdf"]
        XCTAssertTrue(cloudFile.exists, "Files that are only in iCloud are listed")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '12 KB'")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '.icloud'")).firstMatch.exists)
        cloudFile.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Download Now"].waitForExistence(timeout: 3))
    }

    func testIconView() {
        openMoreMenu("Icons")
        XCTAssertTrue(app.staticTexts["photo.jpg"].waitForExistence(timeout: 3))
        app.staticTexts["Docs"].tap()
        XCTAssertTrue(app.staticTexts["nested.txt"].waitForExistence(timeout: 3))
    }

    // MARK: Viewers

    func testTextAndMarkdownViewers() {
        app.staticTexts["notes.md"].tap()
        XCTAssertTrue(app.staticTexts["Project Notes"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Done item"].exists)
        goBack()

        app.staticTexts["hello.txt"].tap()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.textViews.firstMatch.value as? String, "Hello from a plain text file.")
    }

    func testImageAndPDFViewers() {
        app.staticTexts["photo.jpg"].tap()
        XCTAssertTrue(app.navigationBars["photo.jpg"].waitForExistence(timeout: 5))
        goBack()

        app.staticTexts["report.pdf"].tap()
        XCTAssertTrue(app.staticTexts["1 of 2"].waitForExistence(timeout: 5))
    }

    func testGalleryMixesPhotosAndVideos() {
        // Opening a photo: swipe to the video next to it (sorted by name: clip.mp4, photo.jpg).
        app.staticTexts["photo.jpg"].tap()
        XCTAssertTrue(app.navigationBars["photo.jpg"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["videoMute"].exists, "No video controls on a photo")
        swipeGallery("right")
        XCTAssertTrue(app.navigationBars["clip.mp4"].waitForExistence(timeout: 5), "Swiping from a photo reaches the video")

        // The video plays inline, muted.
        let mute = app.buttons["videoMute"]
        XCTAssertTrue(mute.waitForExistence(timeout: 5))
        XCTAssertEqual(mute.label, "Unmute", "Gallery videos start muted")
        XCTAssertEqual(app.buttons["videoPlayPause"].label, "Pause", "Video autoplays")
        mute.tap()
        XCTAssertEqual(mute.label, "Mute")

        // Swiping back to the photo stops the video.
        swipeGallery("left")
        XCTAssertTrue(app.navigationBars["photo.jpg"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitForDisappearance(app.buttons["videoMute"]))
    }

    func testOpeningVideoShowsGallery() {
        app.staticTexts["clip.mp4"].tap()
        XCTAssertTrue(app.navigationBars["clip.mp4"].waitForExistence(timeout: 5), "Videos open in the gallery, not the full player")
        let playPause = app.buttons["videoPlayPause"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 5))
        playPause.tap()
        XCTAssertEqual(playPause.label, "Play")
        playPause.tap()
        XCTAssertEqual(playPause.label, "Pause")

        // Tapping hides the chrome; only the mute button stays.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        XCTAssertTrue(waitForDisappearance(app.buttons["videoPlayPause"]))
        XCTAssertTrue(app.buttons["videoMute"].exists)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        XCTAssertTrue(app.buttons["videoPlayPause"].waitForExistence(timeout: 3))

        // From a video you can swipe on to the photos.
        swipeGallery("left")
        XCTAssertTrue(app.navigationBars["photo.jpg"].waitForExistence(timeout: 5))
        swipeGallery("right")
        XCTAssertTrue(app.navigationBars["clip.mp4"].waitForExistence(timeout: 5))

        // Full screen opens the system player, with sound.
        app.buttons["videoFullScreen"].tap()
        XCTAssertTrue(waitForDisappearance(app.navigationBars["clip.mp4"], timeout: 5), "Full-screen player covers the gallery")
        closeFullScreenPlayer(returningTo: app.navigationBars["clip.mp4"])

        // Back in the gallery on the same video, still playing, now with sound.
        XCTAssertTrue(app.navigationBars["clip.mp4"].waitForExistence(timeout: 5), "Closing full screen returns to the same video")
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "identifier == 'videoPlayPause' AND label == 'Pause'")).firstMatch.waitForExistence(timeout: 3),
            "Video keeps playing after full screen"
        )
        XCTAssertEqual(app.buttons["videoMute"].label, "Mute", "Full screen turned the sound on")
    }

    func testMutedVideoKeepsMusicPlaying() {
        app.staticTexts["tone.wav"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5))
        // The app, not `windows.firstMatch`: iPadOS can add an empty window (e.g. for the video player).
        let window: XCUIElement = app
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
            .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        XCTAssertTrue(app.staticTexts["clip.mp4"].waitForExistence(timeout: 3))

        // The mini player's buttons are identified by their symbols.
        let musicPlaying = app.buttons["pause.fill"]
        let musicPaused = app.buttons["play.fill"]

        app.staticTexts["clip.mp4"].tap()
        XCTAssertTrue(app.buttons["videoMute"].waitForExistence(timeout: 5))
        XCTAssertTrue(musicPlaying.exists, "A muted video leaves the music playing")

        app.buttons["videoMute"].tap()
        XCTAssertTrue(musicPaused.waitForExistence(timeout: 3), "Unmuting a video pauses the music")
    }

    func testSwipingMiniPlayerAwayKeepsGalleryVideoPlaying() {
        app.staticTexts["tone.wav"].tap()
        XCTAssertTrue(app.buttons["nowPlayingPlayPause"].waitForExistence(timeout: 5))
        let window: XCUIElement = app
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
            .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        let mini = app.otherElements["miniPlayer"]
        XCTAssertTrue(mini.waitForExistence(timeout: 3))

        app.staticTexts["clip.mp4"].tap()
        let playPause = app.buttons["videoPlayPause"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["videoMute"].label, "Unmute", "Gallery video is muted, so the music keeps playing")

        // Stop the music by swiping the mini player away; the video carries on.
        mini.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: mini.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)), withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(waitForDisappearance(mini), "Music stopped")
        sleep(2)
        XCTAssertTrue(app.navigationBars["clip.mp4"].exists, "Still on the same video")
        XCTAssertEqual(playPause.label, "Pause", "The video is still playing")
    }

    func testGalleryHidesTabBarInLandscape() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("The tab bar only moves out of the way on iPhone")
        }
        app.staticTexts["clip.mp4"].tap()
        XCTAssertTrue(app.buttons["videoPlayPause"].waitForExistence(timeout: 5))
        XCTAssertTrue(tabButton("tags").isHittable, "Tab bar shows in portrait")

        // Twice: on Pro Max iPhones landscape is regular width, and rotating back used to crash.
        for orientation in [UIDeviceOrientation.landscapeLeft, .landscapeRight] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(waitForDisappearance(tabButton("tags"), timeout: 5), "Landscape video fills the screen")
            XCTAssertFalse(app.tabBars.firstMatch.exists, "No tab bar in landscape")
            XCTAssertTrue(app.buttons["videoPlayPause"].exists, "Video controls stay")

            XCUIDevice.shared.orientation = .portrait
            XCTAssertTrue(tabButton("tags").waitForExistence(timeout: 5), "The tab bar comes back in portrait")
            XCTAssertEqual(app.state, .runningForeground)
        }
    }

    func testMusicPlayerAndMiniPlayer() {
        app.staticTexts["tone.wav"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5), "Now Playing should show a Pause button while playing")
        XCTAssertTrue(app.staticTexts["tone"].exists)
        XCTAssertTrue(app.staticTexts["0:02"].waitForExistence(timeout: 6), "Playback position should advance")

        // Dismiss the Now Playing sheet; the mini player should remain.
        // The app, not `windows.firstMatch`: iPadOS can add an empty window (e.g. for the video player).
        let window: XCUIElement = app
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
            .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        XCTAssertTrue(app.staticTexts["hello.txt"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["tone"].exists, "Mini player should be visible")

        app.buttons["Pause"].tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 3))

        app.staticTexts["tone"].press(forDuration: 1.2)
        app.buttons["Stop Playback"].tap()
        XCTAssertTrue(waitForDisappearance(app.staticTexts["tone"]))
    }

    func testEqualizer() {
        app.staticTexts["tone.wav"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5))
        app.buttons["Equalizer"].tap()

        let toggle = app.switches["Equalizer"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        XCTAssertEqual(toggle.value as? String, "0", "Equalizer starts off")
        toggle.switches.firstMatch.tap()
        XCTAssertEqual(toggle.value as? String, "1")

        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Preset'")).firstMatch.tap()
        let rock = app.buttons["Rock"]
        XCTAssertTrue(rock.waitForExistence(timeout: 3))
        rock.tap()
        let bass = app.descendants(matching: .any)["32 hertz"]
        XCTAssertTrue(bass.waitForExistence(timeout: 3))
        XCTAssertEqual(bass.value as? String, "+5.0 decibels")

        // Drag the 32 Hz band to the top: the curve becomes custom.
        bass.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: bass.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -0.2)))
        XCTAssertEqual(bass.value as? String, "+12.0 decibels")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Custom' OR value CONTAINS 'Custom'")).firstMatch.exists)

        app.buttons["Reset"].tap()
        XCTAssertEqual(bass.value as? String, "+0.0 decibels")

        app.navigationBars["Equalizer"].buttons["Done"].tap()
        XCTAssertTrue(waitForDisappearance(app.navigationBars["Equalizer"]))
        let elapsed = app.staticTexts.matching(NSPredicate(format: "label MATCHES '^[0-9]+:[0-9][0-9]$'")).firstMatch
        let before = elapsed.label
        sleep(2)
        XCTAssertNotEqual(elapsed.label, before, "Music keeps playing with the equalizer on")
    }

    // MARK: Tags

    func testTagFilesAndBrowseByTag() {
        app.staticTexts["hello.txt"].press(forDuration: 1.2)
        app.buttons["Tags…"].tap()
        let red = app.buttons["tagRow-Red"]
        XCTAssertTrue(red.waitForExistence(timeout: 3))
        red.tap()
        XCTAssertTrue(red.isSelected)

        // Every row keeps its checkmark in sync, not just the first one changed.
        let blue = app.buttons["tagRow-Blue"]
        blue.tap()
        XCTAssertTrue(blue.isSelected)
        XCTAssertTrue(red.isSelected)
        blue.tap()
        XCTAssertFalse(blue.isSelected)
        XCTAssertTrue(red.isSelected)

        // Create a custom tag; it's applied straight away.
        let field = app.textFields["Tag Name"]
        field.tap()
        // Return adds the tag, like the Add button.
        field.typeText("Work\n")
        // In the iPad's smaller sheet the new row starts below the fold.
        if !app.buttons["tagRow-Work"].waitForExistence(timeout: 2) { app.buttons["tagRow-Green"].swipeUp() }
        XCTAssertTrue(app.buttons["tagRow-Work"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["tagRow-Work"].isSelected)
        app.navigationBars["Tags"].buttons["Done"].tap()

        let dots = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Tags: Red, Work'")).firstMatch
        XCTAssertTrue(dots.waitForExistence(timeout: 3), "Row shows the file's tags")

        // Search matches tag names.
        let search = openSearch()
        search.typeText("Work")
        XCTAssertTrue(app.staticTexts["hello.txt"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["notes.md"].exists)
        app.buttons["closeSearch"].tap()

        openTab("tags")
        tagRow("Work").tap()
        XCTAssertTrue(app.navigationBars["Work"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["hello.txt"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["notes.md"].exists)
    }

    func testRenameAndDeleteTag() {
        app.staticTexts["notes.md"].press(forDuration: 1.2)
        app.buttons["Tags…"].tap()
        XCTAssertTrue(app.buttons["tagRow-Blue"].waitForExistence(timeout: 3))
        app.buttons["tagRow-Blue"].tap()
        app.navigationBars["Tags"].buttons["Done"].tap()

        openTab("tags")
        tagRow("Blue").press(forDuration: 1.2)
        app.buttons["Edit Tag…"].tap()
        replaceText(in: app.textFields["Tag Name"], with: "Important")
        app.buttons["Save"].tap()
        XCTAssertTrue(tagRow("Important").waitForExistence(timeout: 5))
        XCTAssertFalse(tagRow("Blue").exists)

        // The renamed tag is still on the file.
        tagRow("Important").tap()
        XCTAssertTrue(app.staticTexts["notes.md"].waitForExistence(timeout: 5))

        goBack()
        tagRow("Important").press(forDuration: 1.2)
        app.buttons["Delete Tag"].tap()
        let confirm = app.alerts.firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.buttons["Delete"].tap()
        XCTAssertTrue(waitForDisappearance(tagRow("Important")))

        openTab("local")
        XCTAssertTrue(app.staticTexts["notes.md"].waitForExistence(timeout: 5))
        let dots = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Tags:'")).firstMatch
        XCTAssertFalse(dots.exists, "Deleting a tag removes it from files")
    }

    // MARK: Settings

    func testSettingsHideTagsAndControlGalleryVideos() {
        // Tag a file so there's something to hide.
        app.staticTexts["hello.txt"].press(forDuration: 1.2)
        app.buttons["Tags…"].tap()
        app.buttons["tagRow-Red"].tap()
        app.navigationBars["Tags"].buttons["Done"].tap()
        let dots = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Tags: Red'")).firstMatch
        XCTAssertTrue(dots.waitForExistence(timeout: 3))

        openTab("settings")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        app.switches["Show Tags on Files"].switches.firstMatch.tap()
        app.switches["Autoplay Videos"].switches.firstMatch.tap()
        app.switches["Start Videos Muted"].switches.firstMatch.tap()
        openTab("local")

        XCTAssertTrue(waitForDisappearance(dots), "Tag indicators hidden after names")

        app.staticTexts["clip.mp4"].tap()
        XCTAssertTrue(app.buttons["videoPlayPause"].waitForExistence(timeout: 5))
        sleep(1)
        XCTAssertEqual(app.buttons["videoPlayPause"].label, "Play", "Video waits to be played when autoplay is off")
        XCTAssertEqual(app.buttons["videoMute"].label, "Mute", "Video has sound when auto-mute is off")
    }

    func testResetAllSettingsAndClearCache() {
        openMoreMenu("Icons")
        XCTAssertFalse(app.cells.staticTexts["hello.txt"].waitForExistence(timeout: 2), "Icon view has no list rows")

        openTab("settings")
        let reset = app.buttons["resetAllSettings"]
        for _ in 0..<4 where !reset.isHittable { app.swipeUp() }
        reset.tap()
        app.buttons.matching(NSPredicate(format: "label == 'Reset All Settings' AND identifier != 'resetAllSettings'")).firstMatch.tap()
        XCTAssertTrue(app.alerts["All settings were reset."].waitForExistence(timeout: 3))
        app.alerts.buttons["OK"].tap()

        let clear = app.buttons["clearCache"]
        clear.tap()
        app.buttons.matching(NSPredicate(format: "label == 'Clear Cache' AND identifier != 'clearCache'")).firstMatch.tap()
        XCTAssertTrue(app.alerts["Cache cleared."].waitForExistence(timeout: 5))
        app.alerts.buttons["OK"].tap()

        openTab("local")
        XCTAssertTrue(app.cells.staticTexts["hello.txt"].waitForExistence(timeout: 3), "Back to the list view")
    }

    func testNewTagFromFileGetsAnIcon() {
        app.staticTexts["hello.txt"].press(forDuration: 1.2)
        app.buttons["Tags…"].tap()
        let field = app.textFields["Tag Name"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText("Starred")
        // The new-tag section offers the same icons as the tag editor, in a scrolling row.
        let heart = app.buttons["tagIcon-heart.fill"]
        XCTAssertTrue(heart.waitForExistence(timeout: 3))
        heart.tap()
        XCTAssertTrue(heart.isSelected)
        app.buttons["Add"].firstMatch.tap()
        // In the iPad's smaller sheet the new row starts below the fold.
        if !app.buttons["tagRow-Starred"].waitForExistence(timeout: 2) { app.buttons["tagRow-Green"].swipeUp() }
        XCTAssertTrue(app.buttons["tagRow-Starred"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["tagRow-Starred"].isSelected)
        app.navigationBars["Tags"].buttons["Done"].tap()

        openTab("tags")
        tagRow("Starred").press(forDuration: 1.2)
        app.buttons["Edit Tag…"].tap()
        XCTAssertTrue(app.buttons["tagIcon-heart.fill"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["tagIcon-heart.fill"].isSelected, "The icon was saved with the tag")
    }

    func testTagIcons() {
        openTab("tags")
        tagRow("Red").press(forDuration: 1.2)
        app.buttons["Edit Tag…"].tap()
        let star = app.buttons["tagIcon-star.fill"]
        XCTAssertTrue(star.waitForExistence(timeout: 3))
        star.tap()
        XCTAssertTrue(star.isSelected)
        app.buttons["Save"].tap()
        XCTAssertTrue(waitForDisappearance(app.navigationBars["Edit Tag"]))

        // The icon is remembered.
        tagRow("Red").press(forDuration: 1.2)
        app.buttons["Edit Tag…"].tap()
        XCTAssertTrue(app.buttons["tagIcon-star.fill"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["tagIcon-star.fill"].isSelected)

        // Back to no icon.
        app.buttons["tagIcon-No Icon"].tap()
        XCTAssertTrue(app.buttons["tagIcon-No Icon"].isSelected)
        XCTAssertFalse(app.buttons["tagIcon-star.fill"].isSelected)
        XCTAssertFalse(app.textFields["Type an emoji"].exists, "Tags have no emoji icons")
    }

    // MARK: Music player

    func testSwipeMiniPlayerAwayStopsPlayback() {
        app.staticTexts["tone.wav"].tap()
        XCTAssertTrue(app.buttons["nowPlayingPlayPause"].waitForExistence(timeout: 5))
        let window: XCUIElement = app
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
            .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        let mini = app.otherElements["miniPlayer"]
        XCTAssertTrue(mini.waitForExistence(timeout: 3))
        XCTAssertTrue(waitForDisappearance(app.buttons["nowPlayingPlayPause"]), "Full player is closed")

        // A short swipe springs back.
        mini.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: mini.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 0.1)
        sleep(1)
        XCTAssertTrue(mini.exists, "A short swipe doesn't stop playback")
        XCTAssertFalse(app.buttons["nowPlayingPlayPause"].exists, "Swiping isn't mistaken for a tap")

        // A long one stops it.
        mini.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: mini.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)), withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(waitForDisappearance(mini), "Swiping the mini player away stops playback")
        XCTAssertFalse(app.buttons["nowPlayingPlayPause"].exists, "Swiping isn't mistaken for a tap")
    }

    func testNowPlayingLandscapeLayout() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("The side-by-side player is for iPhone in landscape")
        }
        app.staticTexts["tone.wav"].tap()
        let title = app.staticTexts["nowPlayingTitle"]
        let playPause = app.buttons["nowPlayingPlayPause"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 5))

        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        let width = app.frame.width
        XCTAssertGreaterThan(width, app.frame.height, "Device is in landscape")
        XCTAssertLessThan(title.frame.midX, width / 2, "Title is on the left half")
        XCTAssertGreaterThan(playPause.frame.midX, width / 2, "Controls are on the right half")
        XCTAssertLessThan(abs(title.frame.midY - playPause.frame.midY), app.frame.height / 2, "Side by side, not stacked")
    }

    // MARK: Connections, archives, text editing

    func testConnectionsTabAddMenu() {
        openTab("network")
        XCTAssertTrue(app.navigationBars["Connections"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["No Connections"].exists, "Nothing is listed before anything is added")
        XCTAssertFalse(app.staticTexts["iCloud Drive"].exists, "No separate iCloud Drive section")

        app.buttons["addServerMenu"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'SMB'")).firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Nextcloud'")).firstMatch.exists)
        // Menu items don't keep accessibility identifiers; find it by its title.
        let folder = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Folder from Files'")).firstMatch
        XCTAssertTrue(folder.exists)
        let description = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'iCloud Drive and other cloud storage' OR value CONTAINS 'iCloud Drive and other cloud storage'")).firstMatch
        XCTAssertTrue(description.exists || folder.label.contains("iCloud Drive"), "Folder from Files mentions iCloud Drive")
    }

    /// A drive that's plugged in but not added yet is offered in Connections. Removing a folder
    /// that no companion app follows doesn't mention one.
    func testNewDriveIsOfferedAndFolderRemoves() {
        app.terminate()
        app.launchArguments = ["-FileCatUITestReset", "YES", "-FileCatUITestDrive", "USB STICK", "-FileCatUITestLocation", "Tunes"]
        app.launch()
        openTab("network")
        let drive = app.cells.containing(.staticText, identifier: "USB STICK").firstMatch
        XCTAssertTrue(drive.waitForExistence(timeout: 5), "The plugged-in drive is offered")
        XCTAssertTrue(app.buttons["addNewDrive"].exists)
        drive.swipeLeft()
        app.buttons["Ignore"].tap()
        XCTAssertTrue(waitForDisappearance(drive), "Ignored drives go away")

        let folder = app.cells.containing(.staticText, identifier: "Tunes").firstMatch
        XCTAssertTrue(folder.exists)
        folder.swipeLeft()
        app.buttons["Remove"].tap()
        let alert = app.alerts["Remove “Tunes”?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        XCTAssertTrue(alert.staticTexts["The folder itself isn't deleted."].exists, "No companion app is mentioned")
        alert.buttons["Remove"].tap()
        XCTAssertTrue(waitForDisappearance(folder))
    }

    /// A drive's own folder is named with an ID; the connection takes the drive's name instead.
    func testAddedDriveTakesTheDriveName() {
        app.terminate()
        app.launchArguments = ["-FileCatUITestReset", "YES", "-FileCatUITestDrive", "USB STICK", "-FileCatUITestLocation", "DRIVE"]
        app.launch()
        openTab("network")
        let drive = app.cells.containing(.staticText, identifier: "USB STICK").firstMatch
        XCTAssertTrue(drive.waitForExistence(timeout: 5), "The connection is named after the drive")
        XCTAssertFalse(app.buttons["addNewDrive"].exists, "The drive isn't offered as new any more")
        let ids = app.staticTexts.matching(NSPredicate(format: "label MATCHES '^[0-9A-Fa-f-]{16,}$'"))
        XCTAssertEqual(ids.count, 0, "No ID is shown")
    }

    func testCompressBrowseAndExtractArchive() {
        app.staticTexts["Docs"].press(forDuration: 1.2)
        app.buttons["Compress"].tap()
        app.buttons["ZIP"].firstMatch.tap()
        let archive = app.staticTexts["Docs.zip"]
        XCTAssertTrue(archive.waitForExistence(timeout: 10), "Compressing makes Docs.zip next to the folder")

        archive.tap()
        XCTAssertTrue(app.navigationBars["Docs.zip"].waitForExistence(timeout: 5))
        app.staticTexts["Docs"].tap()
        XCTAssertTrue(app.staticTexts["nested.txt"].waitForExistence(timeout: 5), "Folders inside the archive can be browsed")
        XCTAssertFalse(app.staticTexts[".Cloud Report.pdf.icloud"].exists, "Hidden files stay hidden")
        app.staticTexts["nested.txt"].tap()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.textViews.firstMatch.value as? String, "Nested file", "Files inside the archive open")
        goBack()
        goBack()

        app.buttons["extractAll"].tap()
        let done = app.alerts.matching(NSPredicate(format: "label BEGINSWITH 'Extracted'")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        XCTAssertTrue(done.label.contains("Docs 2"), done.label)
        done.buttons["OK"].tap()
        goBack()
        XCTAssertTrue(app.staticTexts["Docs 2"].waitForExistence(timeout: 5), "The archive was extracted next to it")
    }

    func testNewTextFileAndEditAsText() {
        openAddMenu("Create Text File")
        let alert = app.alerts["New Text File"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        replaceText(in: alert.textFields.firstMatch, with: "draft")
        alert.buttons["Create"].tap()
        if !waitForDisappearance(alert, timeout: 2) { alert.buttons["Create"].tap() }

        let editor = app.textViews["textEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "The new file opens in the editor")
        editor.tap()
        editor.typeText("First line")
        app.buttons["saveText"].tap()
        XCTAssertTrue(waitForDisappearance(editor, timeout: 5))

        app.staticTexts["draft.txt"].tap()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.textViews.firstMatch.value as? String, "First line")

        // Edit from the viewer; it shows the change afterwards.
        app.buttons["editText"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        // Put the cursor at the end of the first line.
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.03)).tap()
        editor.typeText(" and more")
        app.buttons["saveText"].tap()
        XCTAssertTrue(waitForDisappearance(editor, timeout: 5))
        let viewer = app.textViews.firstMatch
        XCTAssertTrue(viewer.waitForExistence(timeout: 5))
        XCTAssertEqual(viewer.value as? String, "First line and more")
        goBack()

        // Any file can be edited as text from its context menu.
        app.staticTexts["notes.md"].press(forDuration: 1.2)
        app.buttons["Edit as Text"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue((editor.value as? String)?.hasPrefix("# Project Notes") == true)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(waitForDisappearance(editor, timeout: 5))
    }

    // MARK: Title menu, activity, long cat

    func testTitleMenuGoesBackUpThePath() throws {
        XCTAssertTrue(app.buttons["addMenu"].exists, "Creating and importing are in the + menu")
        app.staticTexts["Docs"].tap()
        XCTAssertTrue(app.staticTexts["nested.txt"].waitForExistence(timeout: 3))
        let menu = app.buttons["titleMenu"].firstMatch
        guard menu.waitForExistence(timeout: 2) else { throw XCTSkip("The title pill is iPhone only; iPad uses the bar's title menu.") }
        menu.tap()
        let root = app.buttons["Local Storage"].firstMatch
        XCTAssertTrue(root.waitForExistence(timeout: 3), "The menu lists the folders on the way here")
        root.tap()
        XCTAssertTrue(app.staticTexts["hello.txt"].waitForExistence(timeout: 3), "Back at the top of Local Storage")

        openTab("network")
        app.buttons["titleMenu"].firstMatch.tap()
        XCTAssertTrue(app.buttons["All Connections"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Add Connection"].firstMatch.exists, "Connections' title menu can add connections")
    }

    func testActivityIndicatorShowsCopies() {
        app.staticTexts["hello.txt"].press(forDuration: 1.2)
        app.buttons["Copy To…"].tap()
        XCTAssertTrue(app.navigationBars["Copy “hello.txt”"].waitForExistence(timeout: 3))
        app.cells.staticTexts["Local Storage"].firstMatch.tap()
        let pickerDocs = app.collectionViews["folderPicker"].staticTexts["Docs"]
        XCTAssertTrue(pickerDocs.waitForExistence(timeout: 3))
        pickerDocs.tap()
        XCTAssertTrue(app.navigationBars["Docs"].waitForExistence(timeout: 3))
        app.navigationBars["Docs"].buttons["Copy"].tap()

        let indicator = app.buttons["activityButton"].firstMatch
        XCTAssertTrue(indicator.waitForExistence(timeout: 5), "The activity indicator appears")
        indicator.tap()
        XCTAssertTrue(app.staticTexts["Copied “hello.txt”"].waitForExistence(timeout: 5), "The copy is listed")
        app.buttons["Clear"].tap()
        // With nothing left to show, the indicator goes away (on iPad taking its popover along).
        if app.buttons["Done"].firstMatch.waitForExistence(timeout: 1) { app.buttons["Done"].firstMatch.tap() }
        XCTAssertTrue(waitForDisappearance(app.buttons["activityButton"].firstMatch))
        XCTAssertFalse(app.tabBars.buttons["Activity"].exists, "Activity isn't a tab on iPhone")
    }

    func testSettingsOpensActivityList() {
        openTab("settings")
        let row = app.buttons["settingsActivity"]
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        XCTAssertTrue(row.label.contains("None"), "Nothing has run yet: \(row.label)")
        row.tap()
        XCTAssertTrue(app.staticTexts["No Activity"].waitForExistence(timeout: 3), "The activity list opens even when empty")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(waitForDisappearance(app.staticTexts["No Activity"]))
    }

    func testRunningActivityCanBeCancelled() {
        app.terminate()
        app.launchArguments = ["-FileCatUITestReset", "YES", "-FileCatDemoActivity", "30"]
        app.launch()
        let indicator = app.buttons["activityButton"].firstMatch
        XCTAssertTrue(indicator.waitForExistence(timeout: 10))
        indicator.tap()
        XCTAssertTrue(app.staticTexts["Copying “Holiday Photos”"].waitForExistence(timeout: 3))
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Copied “Holiday Photos”"].waitForExistence(timeout: 3) || app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Cancelled'")).firstMatch.waitForExistence(timeout: 3))
    }

    func testLongCatMeowsOnlyOnAHardPull() {
        openTab("settings")
        for _ in 0..<5 { app.swipeUp() }
        let cat = app.descendants(matching: .any)["longCat"]
        XCTAssertTrue(cat.waitForExistence(timeout: 3))
        XCTAssertEqual(cat.value as? String, "0", "Flinging to the end doesn't count")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.85))
            .press(forDuration: 0.2, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.1)), withVelocity: 600, thenHoldForDuration: 1)
        XCTAssertEqual(cat.value as? String, "1", "A long pull past the end meows once")
    }

    func testLongCatRunsDownToTheTabBarPastTheActivityButton() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("On iPad the activity button floats in the window's corner")
        }
        app.terminate()
        app.launchArguments = ["-FileCatUITestReset", "YES", "-FileCatDemoActivity", "30"]
        app.launch()
        let indicator = app.buttons["activityButton"].firstMatch
        XCTAssertTrue(indicator.waitForExistence(timeout: 10))
        openTab("settings")
        for _ in 0..<5 { app.swipeUp() }
        let cat = app.descendants(matching: .any)["longCat"]
        XCTAssertTrue(cat.waitForExistence(timeout: 3))
        XCTAssertTrue(indicator.exists, "The activity button shows in Settings")
        XCTAssertGreaterThan(cat.frame.maxY, indicator.frame.midY,
                             "The list ends at the tab bar, not above the activity button")
    }

    func testCompanionAppsListsMusiCat() {
        openTab("settings")
        let row = app.buttons["Companion Apps"].firstMatch
        for _ in 0..<5 where !row.isHittable { app.swipeUp() }
        row.tap()
        XCTAssertTrue(app.staticTexts["MusiCat"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["openMusiCat"].exists)
    }

    // MARK: Settings: tags, equalizer

    func testTurningTagsOffHidesThem() {
        XCTAssertTrue(tabButton("tags").waitForExistence(timeout: 3))
        openTab("settings")
        let toggle = app.switches["tagsEnabled"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        toggle.switches.firstMatch.tap()
        XCTAssertFalse(app.switches["Show Tags on Files"].waitForExistence(timeout: 1))
        XCTAssertTrue(waitForDisappearance(tabButton("tags")), "The Tags tab goes away")

        openTab("local")
        app.staticTexts["hello.txt"].press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Rename"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Tags…"].exists, "No tag menu")
    }

    func testCustomTagColor() {
        openTab("tags")
        app.buttons["New Tag"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["customTagColor"].firstMatch.waitForExistence(timeout: 3), "The color picker offers any color")
        XCTAssertTrue(app.buttons["Red"].exists, "…next to the Finder colors")
    }

    func testEqualizerInSettings() {
        openTab("settings")
        let row = app.buttons["equalizerSettings"]
        for _ in 0..<3 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.label.contains("Off"), row.label)
        row.tap()
        let toggle = app.switches["Equalizer"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        toggle.switches.firstMatch.tap()
        goBack()
        XCTAssertTrue(app.buttons["equalizerSettings"].label.contains("Flat"), app.buttons["equalizerSettings"].label)
    }

    // MARK: Helpers

    /// The system player hides its controls after a few seconds, so a tap can land just as they
    /// fade and only toggle them. Keep revealing and closing until the gallery is back.
    private func closeFullScreenPlayer(returningTo gallery: XCUIElement) {
        let close = app.buttons.matching(NSPredicate(format: "label ==[c] 'Close' OR label ==[c] 'Done'")).firstMatch
        for _ in 0..<4 {
            if !close.exists {
                // Reveal the controls with a tap away from the centre play/pause button.
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
            }
            if close.waitForExistence(timeout: 2) {
                close.tap()
            } else {
                // On iPad the player's controls aren't exposed to UI tests; its close button
                // sits in the top-left corner.
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.045)).tap()
            }
            if gallery.waitForExistence(timeout: 2) { return }
        }
        XCTFail("Couldn't close the full-screen player")
    }

    /// Swipes the gallery to the next (`left`) or previous (`right`) item, dragging across the
    /// right-hand part of the window so it lands on the gallery even when the iPad sidebar shows.
    private func swipeGallery(_ direction: String) {
        // The app, not `windows.firstMatch`: iPadOS can add an empty window (e.g. for the video player).
        let window: XCUIElement = app
        let (from, to): (CGFloat, CGFloat) = direction == "left" ? (0.95, 0.55) : (0.55, 0.95)
        window.coordinate(withNormalizedOffset: CGVector(dx: from, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: to, dy: 0.5)), withVelocity: .fast, thenHoldForDuration: 0)
    }

    /// Opens the search pill with the magnifying glass in the top-right corner.
    private func openSearch() -> XCUIElement {
        openMoreMenu("Search")
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        return field
    }

    /// A tab: in the bottom tab bar on iPhone, the top bar (or sidebar) on iPad.
    private func tabButton(_ id: String) -> XCUIElement {
        let labels = ["local": "Local Storage", "tags": "Tags", "network": "Connections", "settings": "Settings"]
        // On iPad, Settings is at the bottom of the sidebar.
        if id == "settings", !app.tabBars.buttons["Settings"].exists {
            let sidebar = app.buttons["sidebarSettings"].firstMatch
            if !sidebar.exists, app.buttons["ToggleSideBar"].firstMatch.exists {
                app.buttons["ToggleSideBar"].firstMatch.tap()
                _ = sidebar.waitForExistence(timeout: 2)
            }
            if sidebar.exists { return sidebar }
        }
        let byID = app.buttons["tab-" + id].firstMatch
        if byID.exists { return byID }
        let bar = app.tabBars.buttons[labels[id] ?? id].firstMatch
        if bar.exists { return bar }
        return app.buttons.matching(NSPredicate(format: "label == %@ AND NOT (identifier BEGINSWITH 'tagRow')", labels[id] ?? id)).firstMatch
    }

    private func openTab(_ id: String) {
        let tab = tabButton(id)
        XCTAssertTrue(tab.waitForExistence(timeout: 3), "Tab \(id) not found")
        tab.tap()
    }

    /// A row in the Tags tab.
    private func tagRow(_ name: String) -> XCUIElement {
        app.cells.staticTexts[name].firstMatch
    }

    private func openMoreMenu(_ item: String) {
        openMenu("More", item)
    }

    private func openAddMenu(_ item: String) {
        openMenu("addMenu", item)
    }

    private func openMenu(_ menu: String, _ item: String) {
        let menuButton = app.buttons[menu]
        XCTAssertTrue(menuButton.waitForExistence(timeout: 3))
        menuButton.tap()
        let button = app.buttons.matching(NSPredicate(format: "label == %@ AND NOT (identifier BEGINSWITH 'tab-')", item)).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 3), "Menu item \(item) not found")
        button.tap()
    }

    private func goBack() {
        app.navigationBars.buttons["BackButton"].firstMatch.tap()
    }

    private func replaceText(in field: XCUIElement, with text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        if let current = field.value as? String, !current.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        field.typeText(text)
    }

    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval = 3) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
