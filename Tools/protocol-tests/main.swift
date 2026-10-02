import CryptoKit
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

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
            if ["webdav", "nextcloud", "sftp", "ftp", "ftps-implicit"].contains(label) { print("  note creating an existing folder succeeded (rclone quirk)") } else { check(false, "creating an existing folder fails") }
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
/// Connects to an SSH server once to learn its key, as the server editor does, then trusts it.
func trustSFTPServer(_ source: inout NetworkSource, password: String, key: Curve25519.Signing.PrivateKey?) async {
    do {
        _ = try await SFTPFileSystem.connect(source: source, password: password, key: key)
        check(false, "unknown host key rejected")
    } catch RemoteError.untrustedHostKey(let fingerprint, let type, let changed) {
        check(!changed && fingerprint.hasPrefix("SHA256:"), "unknown \(type) host key reported (\(fingerprint))")
        source.trustedCertificate = fingerprint
    } catch {
        check(false, "host key check \(error) \(error.localizedDescription)")
    }
}

if mode == "all" || mode == "sftp" {
    var source = NetworkSource(kind: .sftp, name: "sftp", host: "127.0.0.1")
    source.port = 2222
    source.username = "test"
    await trustSFTPServer(&source, password: "secret", key: nil)
    do {
        let fs = try await SFTPFileSystem.connect(source: source, password: "secret", key: nil)
        await exercise(fs, label: "sftp")
        do {
            _ = try await SFTPFileSystem.connect(source: source, password: "wrong", key: nil)
            check(false, "wrong password rejected")
        } catch { check(error as? RemoteError == .authenticationFailed, "wrong password rejected: \(error.localizedDescription)") }
        var changed = source
        changed.trustedCertificate = "SHA256:somethingelse"
        do {
            _ = try await SFTPFileSystem.connect(source: changed, password: "secret", key: nil)
            check(false, "changed host key rejected")
        } catch RemoteError.untrustedHostKey(_, _, let isChange) {
            check(isChange, "changed host key rejected")
        }
        var folder = source
        folder.path = "Music"
        let music = try await SFTPFileSystem.connect(source: folder, password: "secret", key: nil)
        check(try await music.list("/").count >= 3, "start folder")
        await music.close()
    } catch { check(false, "sftp \(error) \(error.localizedDescription)") }
}
if mode == "all" || mode == "openssh" {
    // Key sign-in against OpenSSH with different algorithms; 2223 renews its keys every megabyte.
    let key = Curve25519.Signing.PrivateKey()
    let authorizedKeys = "/tmp/filecat-test-state/sshd/authorized_keys"
    try SSHClientKey.authorizedKeysLine(of: key).write(toFile: authorizedKeys, atomically: true, encoding: .utf8)
    for port in [2223, 2224, 2225] {
        var source = NetworkSource(kind: .sftp, name: "openssh", host: "127.0.0.1")
        source.port = port
        source.username = NSUserName()
        source.path = serverRoot
        await trustSFTPServer(&source, password: "", key: key)
        do {
            let fs = try await SFTPFileSystem.connect(source: source, password: "", key: key)
            await exercise(fs, label: "openssh-\(port)")
        } catch { check(false, "openssh \(port) \(error) \(error.localizedDescription)") }
    }
    var source = NetworkSource(kind: .sftp, name: "openssh", host: "127.0.0.1")
    source.port = 2223
    source.username = NSUserName()
    await trustSFTPServer(&source, password: "", key: key)
    do {
        _ = try await SFTPFileSystem.connect(source: source, password: "secret", key: Curve25519.Signing.PrivateKey())
        check(false, "unknown key rejected")
    } catch { check(error.localizedDescription.contains("only accepts SSH keys"), "unknown key rejected: \(error.localizedDescription)") }
}
if mode == "all" || mode == "ftp" {
    var source = NetworkSource(kind: .ftp, name: "ftp", host: "127.0.0.1")
    source.port = 2121
    source.username = "test"
    do {
        let fs = try await RemoteConnections.connect(source, password: "secret")
        await exercise(fs, label: "ftp")
        do {
            _ = try await RemoteConnections.connect(source, password: "wrong")
            check(false, "wrong password rejected")
        } catch { check(error as? RemoteError == .authenticationFailed, "wrong password rejected: \(error.localizedDescription)") }
        var folder = source
        folder.path = "Music"
        let music = try await RemoteConnections.connect(folder, password: "secret")
        check(try await music.list("/").count >= 3, "start folder")
        await music.close()
    } catch { check(false, "ftp \(error) \(error.localizedDescription)") }

    // FTPS with a self-signed certificate, explicit (AUTH TLS) and implicit: rejected until trusted.
    for (port, label) in [(2991, "ftps-explicit"), (2990, "ftps-implicit")] {
        var secure = source
        secure.port = port
        if port == 2990 { secure.host = "ftps://127.0.0.1" }
        do {
            _ = try await RemoteConnections.connect(secure, password: "secret")
            check(false, "\(label) untrusted certificate rejected")
        } catch RemoteError.untrustedCertificate(let fingerprint, let summary) {
            check(true, "\(label) untrusted certificate reported (\(summary))")
            secure.trustedCertificate = fingerprint
        } catch { check(false, "\(label) certificate \(error) \(error.localizedDescription)") }
        do {
            let fs = try await RemoteConnections.connect(secure, password: "secret")
            await exercise(fs, label: label)
        } catch { check(false, "\(label) \(error) \(error.localizedDescription)") }
    }
    // Servers that insist on TLS session reuse for data connections can't work: say so.
    var reuse = source
    reuse.port = 2992
    do {
        _ = try await RemoteConnections.connect(reuse, password: "secret")
        check(false, "session reuse requirement reported")
    } catch RemoteError.untrustedCertificate(let fingerprint, _) {
        reuse.trustedCertificate = fingerprint
        do {
            _ = try await RemoteConnections.connect(reuse, password: "secret")
            check(false, "session reuse requirement reported")
        } catch { check(error.localizedDescription.contains("require_ssl_reuse"), "session reuse requirement reported: \(error.localizedDescription)") }
    } catch { check(false, "session reuse \(error)") }
    var listOnly = source
    listOnly.port = 2122
    do {
        let fs = try await RemoteConnections.connect(listOnly, password: "secret")
        await exercise(fs, label: "ftp-list")
    } catch { check(false, "ftp-list \(error) \(error.localizedDescription)") }

    // LIST parsing, for servers without MLSD.
    let unix = FTPListing.parseLIST("-rw-r--r--    1 1000     1000           23 Jan 10  2024 hello world.txt")
    check(unix?.entry.name == "hello world.txt" && unix?.entry.size == 23 && unix?.entry.isDirectory == false, "LIST unix file")
    let folderLine = FTPListing.parseLIST("drwxr-xr-x 2 me staff 4096 Mar  3 12:34 Music")
    check(folderLine?.entry.isDirectory == true && folderLine?.entry.modified != nil, "LIST unix folder")
    check(FTPListing.parseLIST("lrwxrwxrwx 1 me staff 7 Mar  3 12:34 media -> /volume1")?.entry.name == "media", "LIST link")
    let windows = FTPListing.parseLIST("01-10-26  02:15PM       <DIR>          Old Stuff")
    check(windows?.entry.name == "Old Stuff" && windows?.entry.isDirectory == true, "LIST windows folder")
    check(FTPListing.parseLIST("total 12") == nil, "LIST skips total")
    check(FTPControl.quotedPath(in: "\"/home/a \"\"b\"\"\" is current") == "/home/a \"b\"", "PWD quotes")
    check(FTPControl.extendedPassivePort(in: "Entering Extended Passive Mode (|||6446|)") == 6446, "EPSV port")
    check(FTPControl.passivePort(in: "Entering Passive Mode (10,0,0,2,195,149)") == 195 * 256 + 149, "PASV port")
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
