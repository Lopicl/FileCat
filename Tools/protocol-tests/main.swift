import Foundation

// Where servers.sh puts the shared test files.
let serverRoot = ProcessInfo.processInfo.environment["FILECAT_TEST_ROOT"] ?? "/tmp/filecat-test-server"

func check(_ condition: Bool, _ message: String) {
    print(condition ? "  ok   \(message)" : "  FAIL \(message)")
    if !condition { failures += 1 }
}
nonisolated(unsafe) var failures = 0

func exercise(_ fs: any RemoteFileSystem, label: String, root: String = "/") async {
    print("== \(label)")
    do {
        let entries = try await fs.list(root)
        print("  root: " + entries.map { $0.name + ($0.isDirectory ? "/" : "(\($0.size ?? -1))") }.sorted().joined(separator: ", "))
        check(entries.contains { $0.name == "hello.txt" && !$0.isDirectory && $0.size == 23 }, "lists hello.txt with size")
        check(entries.contains { $0.name == "Music" && $0.isDirectory }, "lists Music folder")
        check(entries.first { $0.name == "hello.txt" }?.modified != nil, "has modification date")
        let music = try await fs.list(RemotePath.join(root, "Music"))
        check(music.count >= 3, "lists Music contents (\(music.count))")

        let range = try await fs.read(RemotePath.join(root, "hello.txt"), offset: 6, length: 4)
        check(String(decoding: range, as: UTF8.self) == "over", "ranged read")

        let dest = URL.temporaryDirectory.appending(path: "dl-\(label).bin")
        try? FileManager.default.removeItem(at: dest)
        let start = Date()
        try await fs.download(RemotePath.join(root, "big.bin"), to: dest) { _ in }
        let same = FileManager.default.contentsEqual(atPath: dest.path, andPath: serverRoot + "/big.bin")
        check(same, String(format: "download 5 MB matches (%.2fs)", Date().timeIntervalSince(start)))

        let folder = RemotePath.join(root, "Test Folder")
        try? await fs.delete(folder, isDirectory: true)
        try await fs.createFolder(folder)
        let upload = URL.temporaryDirectory.appending(path: "up.bin")
        try Data((0..<300_000).map { UInt8($0 % 251) }).write(to: upload)
        try await fs.upload(upload, to: RemotePath.join(folder, "up.bin")) { _ in }
        let back = URL.temporaryDirectory.appending(path: "back-\(label).bin")
        try? FileManager.default.removeItem(at: back)
        try await fs.download(RemotePath.join(folder, "up.bin"), to: back) { _ in }
        check(FileManager.default.contentsEqual(atPath: back.path, andPath: upload.path), "upload round-trips")
        try await fs.createFolder(RemotePath.join(folder, "Sub"))
        try await fs.move(RemotePath.join(folder, "up.bin"), to: RemotePath.join(folder, "renamed ü.bin"))
        let after = try await fs.list(folder).map(\.name).sorted()
        check(after == ["Sub", "renamed ü.bin"], "rename (\(after))")
        do {
            try await fs.createFolder(RemotePath.join(folder, "Sub"))
            // rclone's WebDAV server accepts this; real servers answer 405.
            if label == "webdav" || label == "nextcloud" { print("  note creating an existing folder succeeded (rclone quirk)") } else { check(false, "creating an existing folder fails") }
        } catch {
            check(true, "creating an existing folder fails: \(error.localizedDescription)")
        }
        do {
            _ = try await fs.list(RemotePath.join(root, "Missing"))
            check(false, "missing folder fails")
        } catch {
            check(true, "missing folder fails: \(error.localizedDescription)")
        }
        try await fs.delete(folder, isDirectory: true)
        check(!FileManager.default.fileExists(atPath: serverRoot + "/Test Folder"), "recursive delete")
    } catch {
        check(false, "\(label) threw \(error) — \(error.localizedDescription)")
    }
    await fs.close()
}

let mode = CommandLine.arguments.dropFirst().first ?? "all"
if mode == "all" || mode == "webdav" {
    var source = NetworkSource(kind: .webdav, name: "dav", host: "http://127.0.0.1:8081/")
    source.username = "test"
    do {
        let fs = try await RemoteConnections.connect(source, password: "secret")
        await exercise(fs, label: "webdav")
        do {
            _ = try await RemoteConnections.connect(source, password: "wrong")
            check(false, "wrong password rejected")
        } catch { check(error as? RemoteError == .authenticationFailed, "wrong password rejected: \(error.localizedDescription)") }
    } catch { check(false, "webdav connect \(error)") }
}
if mode == "all" || mode == "nfs" {
    var source = NetworkSource(kind: .nfs, name: "nfs", host: "127.0.0.1")
    source.port = 12049
    source.path = "/"
    do {
        let fs = try await RemoteConnections.connect(source)
        await exercise(fs, label: "nfs")
        print("  exports: \((try? await NFSFileSystem.listExports(source: source)) ?? ["error"])")
    } catch { check(false, "nfs connect \(error) \(error.localizedDescription)") }
}
if mode == "all" || mode == "smb" {
    var source = NetworkSource(kind: .smb, name: "smb", host: "127.0.0.1")
    source.port = Int(ProcessInfo.processInfo.environment["SMBPORT"] ?? "4451")
    source.path = ProcessInfo.processInfo.environment["SMBSHARE"] ?? "Media"
    source.username = ProcessInfo.processInfo.environment["SMBUSER"] ?? NSUserName()
    let password = ProcessInfo.processInfo.environment["SMBPASS"] ?? "secret"
    do {
        let shares = try await SMBFileSystem.listShares(source: source, password: password)
        check(shares.contains { $0.caseInsensitiveCompare(source.path) == .orderedSame }, "share list \(shares)")
    } catch { check(false, "share list \(error) \(error.localizedDescription)") }
    do {
        let fs = try await RemoteConnections.connect(source, password: password)
        await exercise(fs, label: "smb")
        do {
            _ = try await RemoteConnections.connect(source, password: "wrong")
            check(false, "wrong password rejected")
        } catch { check(error as? RemoteError == .authenticationFailed, "wrong password rejected: \(error.localizedDescription)") }
        var multi = source
        multi.path = ""
        let all = try await RemoteConnections.connect(multi, password: password)
        let roots = try await all.list("/")
        check(roots.contains { $0.isDirectory }, "share-less root lists shares \(roots.map(\.name))")
        let inShare = try await all.list("/" + source.path)
        check(inShare.contains { $0.name == "hello.txt" }, "browse into share from root")
        await all.close()
    } catch { check(false, "smb connect \(error) \(error.localizedDescription)") }
}
print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
if mode == "dialect" {
    let client = try await SMB2Client.connect(host: "127.0.0.1", port: 4451, user: NSUserName(), password: "secret", domain: "")
    print(String(format: "  negotiated dialect 0x%04X", await client.dialect))
    await client.close()
}
if mode == "all" || mode == "nextcloud" {
    do {
        let session = try await NextcloudLogin.start(server: "http://127.0.0.1:8082")
        check(session.loginURL.absoluteString.hasSuffix("/login/flow"), "login flow started")
        // Simulate the user signing in on the web page.
        _ = try await URLSession.shared.data(from: session.loginURL)
        let credentials = try await session.waitForCompletion()
        check(credentials.loginName == "test" && credentials.appPassword == "secret", "app password received")
        var source = NetworkSource(kind: .nextcloud, name: "nc", host: credentials.server)
        source.username = credentials.loginName
        check(source.webDAVBaseURL?.absoluteString == "http://127.0.0.1:8082/remote.php/dav/files/test/", "DAV address \(source.webDAVBaseURL?.absoluteString ?? "")")
        let fs = try await RemoteConnections.connect(source, password: credentials.appPassword)
        await exercise(fs, label: "nextcloud")
    } catch { check(false, "nextcloud \(error) \(error.localizedDescription)") }
}
