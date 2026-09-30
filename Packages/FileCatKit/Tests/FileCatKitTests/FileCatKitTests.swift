import FileCatKit
import XCTest

final class FileCatKitTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "FileCatKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "Music/Album"), withIntermediateDirectories: true)
        try Data("ID3".utf8).write(to: root.appending(path: "Music/Album/01 Song.mp3"))
        try Data().write(to: root.appending(path: "Music/cover.jpg"))
        try Data().write(to: root.appending(path: "notes.txt"))
        try Data().write(to: root.appending(path: ".hidden.mp3"))
        defaults = UserDefaults(suiteName: "FileCatKitTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testTagsRoundTripThroughExtendedAttributes() throws {
        let file = root.appending(path: "notes.txt")
        try FileTags.write(["Work", "Later"], colors: ["work": .red], to: file)
        XCTAssertEqual(FileTags.read(file), ["Work", "Later"])
        XCTAssertTrue(FileTags.contains(FileTags.read(file), "work"))
        try FileTags.write([], colors: [:], to: file)
        XCTAssertEqual(FileTags.read(file), [])
    }

    func testTagsSavedWithEmojiIconsStillLoad() throws {
        // Earlier builds allowed emoji icons; those tags load without an icon.
        let json = #"[{"name":"Party","color":6,"icon":{"emoji":{"_0":"🎉"}}},{"name":"Work","color":4,"icon":{"symbol":{"_0":"briefcase.fill"}}}]"#
        let tags = try JSONDecoder().decode([FileTag].self, from: Data(json.utf8))
        XCTAssertEqual(tags.map(\.name), ["Party", "Work"])
        XCTAssertNil(tags[0].icon)
        XCTAssertEqual(tags[1].icon, .symbol("briefcase.fill"))
    }

    func testFileKinds() {
        XCTAssertEqual(FileKind(url: URL(filePath: "/a/Song.MP3"), isDirectory: false), .audio)
        XCTAssertEqual(FileKind(url: URL(filePath: "/a/clip.mov"), isDirectory: false), .video)
        XCTAssertEqual(FileKind(url: URL(filePath: "/a/readme.md"), isDirectory: false), .markdown)
        XCTAssertEqual(FileKind(url: URL(filePath: "/a/Folder"), isDirectory: true), .folder)
    }

    func testLinks() throws {
        let link = FileCatLink(action: .open, path: "Music/Album/01 Song.mp3")
        XCTAssertEqual(FileCatLink(url: link.url), link)
        XCTAssertEqual(link.fileURL(in: root)?.lastPathComponent, "01 Song.mp3")
        XCTAssertEqual(FileCatLink(action: .reveal, path: "Music/cover.jpg").fileURL(in: root)?.lastPathComponent, "Music")
        XCTAssertNil(FileCatLink(action: .open, path: "../outside.txt").fileURL(in: root), "Links can't leave the library")
        XCTAssertNil(FileCatLink(url: URL(string: "https://example.com/open?path=a")!))
    }

    func testConnectingRequiresAManifest() throws {
        let library = FileCatLibrary(defaults: defaults)
        XCTAssertThrowsError(try library.connect(to: root)) { error in
            XCTAssertEqual(error as? FileCatLibrary.LibraryError, .notALibrary)
        }
        XCTAssertFalse(library.isConnected)
    }

    func testLibraryListsFilesAndRemembersTheFolder() throws {
        let manifest = LibraryManifest(tags: [FileTag(name: "Favorites", color: .red, icon: .symbol("star.fill"))])
        try manifest.write(to: root)
        XCTAssertTrue(FileCatLibrary.isLibrary(root))

        let library = FileCatLibrary(defaults: defaults)
        try library.connect(to: root)
        XCTAssertEqual(library.manifest?.libraryID, manifest.libraryID)
        XCTAssertEqual(library.tag(named: "favorites")?.icon, .symbol("star.fill"))

        let songs = library.files(ofKinds: [.audio])
        XCTAssertEqual(songs.map(\.relativePath), ["Music/Album/01 Song.mp3"], "Hidden files are skipped")
        XCTAssertEqual(library.files(ofKinds: [.image], under: "Music").map(\.relativePath), ["Music/cover.jpg"])
        XCTAssertEqual(library.link(for: songs[0].url), FileCatLink(action: .open, path: "Music/Album/01 Song.mp3").url)

        // A new instance (next launch) finds the same library again.
        let again = FileCatLibrary(defaults: defaults)
        XCTAssertEqual(again.rootURL?.standardizedFileURL.resolvingSymlinksInPath(), root.standardizedFileURL.resolvingSymlinksInPath())
        again.disconnect()
        XCTAssertFalse(FileCatLibrary(defaults: defaults).isConnected)
    }

    func testSharingServers() throws {
        let request = ServerShareRequest(replyScheme: "MusiCat")
        XCTAssertEqual(request.url.absoluteString, "filecat://share-servers?reply=musicat")
        XCTAssertEqual(ServerShareRequest(url: request.url), request)
        XCTAssertNil(ServerShareRequest(url: URL(string: "filecat://share-servers")!), "A request needs a reply scheme")
        XCTAssertNil(ServerShareRequest(url: URL(string: "filecat://open?path=a")!))

        // Whole seconds, like FileCat stamps them, so the date survives ISO 8601.
        let changed = Date(timeIntervalSince1970: 1_790_000_000)
        let server = SharedServer(id: "A1", kind: "smb", name: "NAS", host: "nas.local", path: "Media/Music", username: "me", passwordChanged: changed)
        let reply = ServerShareReply(servers: [.init(server: server, password: "p@ss/wörd+=?&")])
        let url = reply.url(scheme: "musicat")
        XCTAssertEqual(url.scheme, "musicat")
        XCTAssertEqual(ServerShareReply(url: url), reply)
        XCTAssertNil(ServerShareReply(url: URL(string: "musicat://filecat-servers?servers=%%%")!))

        // The manifest lists servers without passwords, with the same dates.
        var manifest = LibraryManifest(tags: [])
        manifest.servers = [server]
        try manifest.write(to: root)
        XCTAssertEqual(LibraryManifest.read(from: root)?.servers?.first?.passwordChanged, changed)
        let written = try String(contentsOf: LibraryManifest.url(in: root), encoding: .utf8)
        XCTAssertFalse(written.contains("p@ss"))
    }

    func testSharedFoldersAndCompanionUsage() throws {
        // FileCat's bookmark of a folder opens it for the companion app too.
        let music = root.appending(path: "Music")
        var manifest = LibraryManifest(tags: [])
        manifest.locations = [
            SharedLocation(id: "L1", name: "Music", kind: .drive, bookmark: try music.bookmarkData(), isConnected: true),
            SharedLocation(name: "Old", kind: .folder),
        ]
        try manifest.write(to: root)
        let read = try XCTUnwrap(LibraryManifest.read(from: root)?.locations)
        XCTAssertEqual(read.first?.id, "L1")
        let resolved = try XCTUnwrap(read.first?.resolveBookmark())
        XCTAssertEqual(resolved.url.standardizedFileURL.resolvingSymlinksInPath(), music.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertTrue(resolved.isReadable)
        XCTAssertNil(read.last?.resolveBookmark(), "Manifests from older FileCat builds have no bookmarks")

        XCTAssertEqual(CompanionUsage.readAll(from: root), [])
        try CompanionUsage(app: "MusiCat", locationIDs: ["L1"], serverIDs: ["S1"]).write(to: root)
        try CompanionUsage(app: "VidCat", serverIDs: ["S1"]).write(to: root)
        XCTAssertEqual(CompanionUsage.apps(using: "S1", in: root), ["MusiCat", "VidCat"])
        XCTAssertEqual(CompanionUsage.apps(using: "L1", in: root), ["MusiCat"])
        XCTAssertEqual(CompanionUsage.apps(using: "L2", in: root), [])
        try CompanionUsage(app: "MusiCat").write(to: root)
        XCTAssertEqual(CompanionUsage.apps(using: "L1", in: root), [])
    }
}
