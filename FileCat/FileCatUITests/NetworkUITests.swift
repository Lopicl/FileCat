import XCTest

/// Drives the Connections tab against test servers on this Mac. Start them with
/// `Tools/protocol-tests/servers.sh`; each test skips itself when its server isn't running.
///
/// - WebDAV: rclone on 127.0.0.1:8081 (user `test`, password `secret`)
/// - SMB: Samba on 127.0.0.1:4451, share `Media` (user and password from `Tools/protocol-tests`)
/// - NFS: rclone on 127.0.0.1:12049, export `/`
///
/// All three share the folder created by `servers.sh`, which holds `hello.txt`, `Music/` and `Photos/`.
final class NetworkUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-FileCatUITestReset", "YES"]
        app.launch()
        XCTAssertTrue(app.staticTexts["hello.txt"].waitForExistence(timeout: 10))
    }

    func testWebDAVBrowseOpenAndManage() throws {
        try requireServer(port: 8081)
        addServer("WebDAV", host: "http://127.0.0.1:8081/", user: "test", password: "secret")
        openServer("127.0.0.1")

        // Opening a file downloads it, then shows it.
        XCTAssertTrue(app.staticTexts["hello.txt"].waitForExistence(timeout: 10))
        app.staticTexts["hello.txt"].tap()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(app.textViews.firstMatch.value as? String, "hello over the network\n")
        goBack()

        // New folder, rename, delete.
        openAddMenu("Create Folder")
        let alert = app.alerts["New Folder"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        replaceText(in: alert.textFields.firstMatch, with: "UI Test Folder")
        alert.buttons["Create"].tap()
        // Right after launch the keyboard can still be settling and swallow the first tap.
        if !waitForDisappearance(alert, timeout: 2) { alert.buttons["Create"].tap() }
        XCTAssertTrue(app.staticTexts["UI Test Folder"].waitForExistence(timeout: 10))

        app.staticTexts["UI Test Folder"].press(forDuration: 1.2)
        app.buttons["Rename"].tap()
        let rename = app.alerts["Rename"]
        XCTAssertTrue(rename.waitForExistence(timeout: 3))
        replaceText(in: rename.textFields.firstMatch, with: "Renamed Folder")
        rename.buttons["Rename"].tap()
        if !waitForDisappearance(rename, timeout: 2) { rename.buttons["Rename"].tap() }
        XCTAssertTrue(app.staticTexts["Renamed Folder"].waitForExistence(timeout: 10))

        app.staticTexts["Renamed Folder"].press(forDuration: 1.2)
        app.buttons["Delete"].firstMatch.tap()
        let confirm = app.alerts.firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.buttons["Delete"].tap()
        XCTAssertTrue(waitForDisappearance(app.staticTexts["Renamed Folder"], timeout: 10))
    }

    func testWebDAVKeepOfflineAndSaveToLocalStorage() throws {
        try requireServer(port: 8081)
        addServer("WebDAV", host: "http://127.0.0.1:8081/", user: "test", password: "secret")
        openServer("127.0.0.1")

        XCTAssertTrue(app.staticTexts["Music"].waitForExistence(timeout: 10))
        app.staticTexts["Music"].press(forDuration: 1.2)
        app.buttons["Keep Offline"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["Kept offline"].waitForExistence(timeout: 15), "Pinned folder shows the offline badge")

        app.staticTexts["hello.txt"].press(forDuration: 1.2)
        app.buttons["Save to Local Storage"].tap()
        // Local Storage already has a hello.txt, so the copy gets a new name.
        let saved = app.alerts["Saved “hello 2.txt” to Local Storage."]
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        saved.buttons["OK"].tap()

        openTab("local")
        XCTAssertTrue(app.staticTexts["hello 2.txt"].waitForExistence(timeout: 5), "The copy lands next to the existing hello.txt")
    }

    func testWrongPasswordIsReported() throws {
        try requireServer(port: 8081)
        addServer("WebDAV", host: "http://127.0.0.1:8081/", user: "test", password: "wrong", expectSuccess: false)
        let alert = app.alerts["Couldn't Connect"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        XCTAssertTrue(alert.staticTexts["The user name or password is incorrect."].exists)
    }

    func testNextcloudSignInWithBrowser() throws {
        // A stand-in Nextcloud (Tools/protocol-tests/nextcloud_mock.py) that approves the sign-in
        // as soon as its login page loads.
        try requireServer(port: 8082)
        openTab("network")
        app.buttons["addServerMenu"].tap()
        menuItem("Nextcloud").tap()
        type("serverHost", "http://127.0.0.1:8082")
        app.buttons["nextcloudSignIn"].tap()
        // The sign-in page opens, FileCat picks up the app password, connects and saves.
        dismissPasswordPrompt(timeout: 15)
        openServer("127.0.0.1")
        XCTAssertTrue(app.staticTexts["hello.txt"].waitForExistence(timeout: 10))
    }

    func testSMBShareBrowserAndPhotos() throws {
        try requireServer(port: 4451)
        let credentials = try smbCredentials()
        openTab("network")
        app.buttons["addServerMenu"].tap()
        menuItem("SMB").tap()
        type("serverHost", "127.0.0.1")
        type("serverUser", credentials.user)
        type("serverPassword", credentials.password)
        setPort("4451")

        // Browse lists the server's shares; pick one.
        app.buttons["Browse"].tap()
        let share = app.buttons["Media"]
        XCTAssertTrue(share.waitForExistence(timeout: 10))
        share.tap()
        app.buttons["saveServer"].tap()
        dismissPasswordPrompt()

        openServer("Media on 127.0.0.1")
        XCTAssertTrue(app.staticTexts["Photos"].waitForExistence(timeout: 10))
        app.staticTexts["Photos"].tap()
        XCTAssertTrue(app.staticTexts["Sunset.jpg"].waitForExistence(timeout: 10))
        app.staticTexts["Sunset.jpg"].tap()
        XCTAssertTrue(app.navigationBars["Sunset.jpg"].waitForExistence(timeout: 15))
    }

    func testNFSBrowseAndPlayMusic() throws {
        try requireServer(port: 12049)
        openTab("network")
        app.buttons["addServerMenu"].tap()
        menuItem("NFS").tap()
        type("serverHost", "127.0.0.1")
        type("serverShare", "/")
        setPort("12049")
        app.buttons["saveServer"].tap()

        openServer("127.0.0.1:/")
        XCTAssertTrue(app.staticTexts["Music"].waitForExistence(timeout: 10))
        app.staticTexts["Music"].tap()
        let track = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH '.m4a' OR label ENDSWITH '.wav'")).firstMatch
        XCTAssertTrue(track.waitForExistence(timeout: 10))
        track.tap()
        XCTAssertTrue(app.buttons["nowPlayingPlayPause"].waitForExistence(timeout: 15), "Music from the server plays")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ENDSWITH ' of 3'")).firstMatch.waitForExistence(timeout: 5), "The folder's other songs are queued")
        let playing = app.staticTexts.matching(NSPredicate(format: "label MATCHES '^0:0[1-9]$'")).firstMatch
        XCTAssertTrue(playing.waitForExistence(timeout: 15), "The song plays (streamed while it downloads)")
    }

    /// MusiCat asks for FileCat's servers, FileCat asks the user, and MusiCat then plays music
    /// from the server. Needs MusiCat installed on the simulator.
    func testMusiCatImportsServersAndPlaysFromThem() throws {
        try requireServer(port: 8081)
        addServer("WebDAV", host: "http://127.0.0.1:8081/", user: "test", password: "secret")
        XCTAssertTrue(app.staticTexts["127.0.0.1"].waitForExistence(timeout: 10))

        let musiCat = XCUIApplication(bundleIdentifier: "com.lopicl.MusiCat")
        musiCat.launchArguments = ["-MusiCatUITestReset", "YES"]
        musiCat.launch()
        guard musiCat.wait(for: .runningForeground, timeout: 10) else {
            throw XCTSkip("MusiCat isn't installed on this simulator.")
        }
        musiCat.tabBars.buttons["Settings"].tap()
        let importButton = musiCat.buttons["importServers"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 5))
        importButton.tap()

        // FileCat asks first.
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "MusiCat opens FileCat")
        // iOS's save-password prompt tends to show up now, on top of FileCat's question.
        dismissPasswordPrompt(timeout: 3)
        let alert = app.alerts["Share Servers with MusiCat?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Share"].tap()

        // Back in MusiCat with the server, whose password came along.
        XCTAssertTrue(musiCat.wait(for: .runningForeground, timeout: 10), "FileCat hands the servers back to MusiCat")
        let server = musiCat.staticTexts["127.0.0.1"]
        XCTAssertTrue(server.waitForExistence(timeout: 5))
        server.tap()
        musiCat.buttons["Add Music Folder…"].tap()
        let music = musiCat.buttons["Music"]
        XCTAssertTrue(music.waitForExistence(timeout: 10), "The server's folders are listed")
        music.tap()
        musiCat.buttons["useForMusic"].tap()
        XCTAssertTrue(musiCat.buttons["In Library"].waitForExistence(timeout: 5))

        // The songs are in the library, and play (after downloading).
        musiCat.tabBars.buttons["Songs"].tap()
        let songs = musiCat.buttons.matching(NSPredicate(format: "label BEGINSWITH 'stream'"))
        let deadline = Date().addingTimeInterval(20)
        while songs.count < 3, Date() < deadline { sleep(1) }
        XCTAssertEqual(songs.count, 3, "The server's three songs are in the library")
        songs.firstMatch.tap()
        XCTAssertTrue(musiCat.buttons["Pause"].waitForExistence(timeout: 20), "A song from the server plays")
        musiCat.terminate()
    }

    /// Needs a movie at /tmp/filecat-test-server/Videos/clip.mp4.
    func testWebDAVStreamsVideoWhileDownloading() throws {
        try requireServer(port: 8081)
        guard FileManager.default.fileExists(atPath: "/tmp/filecat-test-server/Videos/clip.mp4") else {
            throw XCTSkip("Put a movie at /tmp/filecat-test-server/Videos/clip.mp4 to test streaming.")
        }
        addServer("WebDAV", host: "http://127.0.0.1:8081/", user: "test", password: "secret")
        openServer("127.0.0.1")
        XCTAssertTrue(app.staticTexts["Videos"].waitForExistence(timeout: 10))
        app.staticTexts["Videos"].tap()
        XCTAssertTrue(app.staticTexts["clip.mp4"].waitForExistence(timeout: 10))
        app.staticTexts["clip.mp4"].tap()
        XCTAssertTrue(app.buttons["videoPlayPause"].waitForExistence(timeout: 10), "The gallery opens straight away")
        let playing = app.staticTexts.matching(NSPredicate(format: "label MATCHES '^0:0[1-9]$'")).firstMatch
        XCTAssertTrue(playing.waitForExistence(timeout: 20), "The video plays while it downloads")
    }

    // MARK: Helpers

    private func requireServer(port: UInt16) throws {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(socketDescriptor) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if result != 0 {
            throw XCTSkip("No test server on port \(port). Run Tools/protocol-tests/servers.sh.")
        }
    }

    /// The Samba account set up by `servers.sh` (defaults to the Mac user and "secret").
    private func smbCredentials() throws -> (user: String, password: String) {
        let environment = ProcessInfo.processInfo.environment
        return (environment["FILECAT_SMB_USER"] ?? "lopicl", environment["FILECAT_SMB_PASSWORD"] ?? "secret")
    }

    private func addServer(_ kind: String, host: String, user: String, password: String, expectSuccess: Bool = true) {
        openTab("network")
        app.buttons["addServerMenu"].tap()
        menuItem(kind).tap()
        type("serverHost", host)
        type("serverUser", user)
        type("serverPassword", password)
        app.buttons["saveServer"].tap()
        if expectSuccess { dismissPasswordPrompt() }
    }

    /// iOS offers to save any password typed into an app; say no so it doesn't cover the list.
    private func dismissPasswordPrompt(timeout: TimeInterval = 5) {
        let notNow = app.buttons.matching(NSPredicate(format: "label IN {'Not Now', 'Non ora'}")).firstMatch
        if notNow.waitForExistence(timeout: timeout) {
            notNow.tap()
            _ = waitForDisappearance(notNow)
            sleep(1)
        }
    }

    /// Opens a saved server. The system's save-password prompt can appear late and swallow the
    /// tap, so check the folder opened and try again if not.
    private func openServer(_ name: String) {
        let row = app.staticTexts[name].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Server \(name) wasn't added")
        let title = app.navigationBars[name]
        for _ in 0..<3 {
            dismissPasswordPrompt(timeout: 1)
            if row.isHittable { row.tap() }
            if title.waitForExistence(timeout: 5) { return }
        }
        XCTFail("Couldn't open \(name)")
    }

    /// An item in the + menu; its label also holds the item's description.
    private func menuItem(_ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", title, title + ",")).firstMatch
    }

    private func type(_ identifier: String, _ text: String) {
        let field = app.descendants(matching: .any)[identifier].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), identifier)
        field.tap()
        field.typeText(text)
    }

    private func setPort(_ port: String) {
        let field = app.textFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH 'Port'")).firstMatch
        for _ in 0..<3 where !field.isHittable { app.swipeUp() }
        field.tap()
        field.typeText(port)
    }

    private func openTab(_ id: String) {
        let labels = ["local": "Local Storage", "network": "Connections"]
        var tab = app.buttons["tab-" + id].firstMatch
        if !tab.exists { tab = app.tabBars.buttons[labels[id] ?? id].firstMatch }
        if !tab.exists { tab = app.buttons[labels[id] ?? id].firstMatch }
        XCTAssertTrue(tab.waitForExistence(timeout: 3))
        tab.tap()
    }

    private func openAddMenu(_ item: String) {
        let add = app.buttons["addMenu"]
        XCTAssertTrue(add.waitForExistence(timeout: 3))
        add.tap()
        let button = app.buttons[item].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 3))
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
