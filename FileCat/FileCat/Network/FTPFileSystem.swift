import Foundation

/// Files over FTP (RFC 959), encrypted with TLS (RFC 4217) whenever the server offers it:
/// explicitly with AUTH TLS, or implicitly on port 990. FTP runs one transfer at a time per
/// connection, so each operation borrows one of a few control connections.
actor FTPFileSystem: RemoteFileSystem {
    private static let maxConnections = 3
    /// Idle connections older than this are dropped rather than reused; servers time them out.
    private static let maxIdleTime: TimeInterval = 120

    private let source: NetworkSource
    private let password: String
    private let session: URLSession
    private let trust: FTPTrust
    private var idle: [FTPControl] = []
    private var connectionCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// The start folder as an absolute path on the server, once known.
    private var root: String?

    private init(source: NetworkSource, password: String) {
        self.source = source
        self.password = password
        trust = FTPTrust(trustedFingerprint: source.trustedCertificate)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration, delegate: trust, delegateQueue: nil)
    }

    static func connect(source: NetworkSource, password: String) async throws -> any RemoteFileSystem {
        let fileSystem = FTPFileSystem(source: source, password: password)
        do {
            _ = try await fileSystem.list("/")
        } catch {
            await fileSystem.close()
            throw error
        }
        return fileSystem
    }

    // MARK: Connections

    /// Runs `body` with a control connection of its own. A reused connection that turns out to
    /// have been dropped by the server is replaced once.
    private func withControl<T>(_ body: (FTPControl) async throws -> T) async throws -> T {
        var retried = false
        while true {
            let (control, isNew) = try await checkOut()
            do {
                let result = try await body(control)
                checkIn(control)
                return result
            } catch {
                checkIn(control)
                if !isNew, !retried, Self.isConnectionError(error) {
                    retried = true
                    continue
                }
                throw error
            }
        }
    }

    private func checkOut() async throws -> (FTPControl, isNew: Bool) {
        while true {
            while let control = idle.popLast() {
                if Date().timeIntervalSince(control.lastUsed) < Self.maxIdleTime { return (control, false) }
                discard(control)
            }
            if connectionCount < Self.maxConnections {
                connectionCount += 1
                do {
                    let control = try await FTPControl.open(source: source, password: password, session: session, trust: trust)
                    if root == nil {
                        do {
                            root = try await resolveRoot(control)
                        } catch {
                            discard(control)
                            throw error
                        }
                    }
                    return (control, true)
                } catch {
                    connectionCount -= 1
                    wakeOne()
                    throw error
                }
            }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    /// Returns a connection to the pool, or closes it if it may be out of step with the server.
    private func checkIn(_ control: FTPControl) {
        guard control.isReusable else {
            discard(control)
            return
        }
        control.lastUsed = Date()
        idle.append(control)
        wakeOne()
    }

    private func discard(_ control: FTPControl) {
        control.close()
        connectionCount -= 1
        wakeOne()
    }

    private func wakeOne() {
        if !waiters.isEmpty { waiters.removeFirst().resume() }
    }

    private static func isConnectionError(_ error: Error) -> Bool {
        switch error as? RemoteError {
        case .connectionFailed, .timedOut: true
        default: false
        }
    }

    private func resolveRoot(_ control: FTPControl) async throws -> String {
        let reply = try await control.send("PWD")
        let home = reply.code == 257 ? FTPControl.quotedPath(in: reply.text) ?? "/" : "/"
        let start = source.path.trimmingCharacters(in: .whitespaces)
        if start.isEmpty || start == "~" { return home }
        if start.hasPrefix("/") { return RemotePath.normalized(start) }
        return RemotePath.join(home, RemotePath.components(of: start).joined(separator: "/"))
    }

    private func serverPath(_ path: String) throws -> String {
        guard !path.contains(where: { $0 == "\r" || $0 == "\n" }) else {
            throw RemoteError.unsupported("FTP can't handle names with line breaks.")
        }
        let root = root ?? "/"
        let components = RemotePath.components(of: path)
        return components.isEmpty ? root : RemotePath.join(root, components.joined(separator: "/"))
    }

    // MARK: RemoteFileSystem

    func list(_ path: String) async throws -> [RemoteEntry] {
        try await entries(path).filter { !$0.name.hasPrefix(".") }
    }

    /// Everything in a folder that the server shows, hidden files included.
    private func entries(_ path: String) async throws -> [RemoteEntry] {
        try await withControl { control in
            let full = try serverPath(path)
            var entries: [RemoteEntry] = []
            var links: [String] = []
            if control.features.contains("MLST") {
                for line in try await control.transferText("MLSD \(full)", name: path) {
                    guard let item = FTPListing.parseMLSD(line) else { continue }
                    if item.isLink { links.append(item.entry.name) } else { entries.append(item.entry) }
                }
            } else {
                // LIST takes options as well as a path, so go to the folder and list that.
                let change = try await control.send("CWD \(full)")
                guard change.code == 250 else { throw FTPControl.error(for: change, name: path) }
                for line in try await control.transferText("LIST", name: path) {
                    guard let item = FTPListing.parseLIST(line) else { continue }
                    if item.isLink { links.append(item.entry.name) } else { entries.append(item.entry) }
                }
            }
            // Symbolic links: a link to a folder is one we can change into.
            for name in links {
                let isFolder = try await control.send("CWD \(RemotePath.join(full, name))").code == 250
                entries.append(RemoteEntry(name: name, isDirectory: isFolder, size: nil, modified: nil))
            }
            return entries.filter { $0.name != "." && $0.name != ".." }
        }
    }

    func read(_ path: String, offset: Int64, length: Int) async throws -> Data {
        try await withControl { control in
            var result = Data()
            guard length > 0 else { return result }
            try await control.retrieve(try serverPath(path), name: path, offset: offset) { chunk in
                result.append(chunk.prefix(length - result.count))
                return result.count < length
            }
            return result
        }
    }

    func download(_ path: String, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await withControl { control in
            FileManager.default.createFile(atPath: destination.path(percentEncoded: false), contents: nil)
            let file = try FileHandle(forWritingTo: destination)
            defer { try? file.close() }
            var written: Int64 = 0
            try await control.retrieve(try serverPath(path), name: path, offset: 0) { chunk in
                try file.write(contentsOf: chunk)
                written += Int64(chunk.count)
                progress(written)
                return true
            }
        }
    }

    func upload(_ source: URL, to path: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await withControl { control in
            let file = try FileHandle(forReadingFrom: source)
            defer { try? file.close() }
            try await control.store(try serverPath(path), name: path, from: file, progress: progress)
        }
    }

    func createFolder(_ path: String) async throws {
        try await withControl { control in
            let full = try serverPath(path)
            let reply = try await control.send("MKD \(full)")
            guard reply.code == 257 || reply.code == 250 else {
                if try await control.send("CWD \(full)").code == 250 {
                    throw RemoteError.alreadyExists(RemotePath.name(of: path))
                }
                throw FTPControl.error(for: reply, name: path)
            }
        }
    }

    func delete(_ path: String, isDirectory: Bool) async throws {
        if isDirectory {
            for entry in try await entries(path) {
                try await delete(RemotePath.join(path, entry.name), isDirectory: entry.isDirectory)
            }
        }
        try await withControl { control in
            let reply = try await control.send("\(isDirectory ? "RMD" : "DELE") \(try serverPath(path))")
            guard reply.code == 250 || reply.code == 200 else { throw FTPControl.error(for: reply, name: path) }
        }
    }

    func move(_ path: String, to newPath: String) async throws {
        try await withControl { control in
            let from = try serverPath(path)
            let to = try serverPath(newPath)
            // Many servers replace an existing file; don't.
            if try await control.exists(to) {
                throw RemoteError.alreadyExists(RemotePath.name(of: newPath))
            }
            let start = try await control.send("RNFR \(from)")
            guard start.code == 350 else { throw FTPControl.error(for: start, name: path) }
            let finish = try await control.send("RNTO \(to)")
            guard finish.code == 250 || finish.code == 200 else { throw FTPControl.error(for: finish, name: newPath) }
        }
    }

    func close() async {
        idle.forEach { $0.close() }
        idle = []
        session.invalidateAndCancel()
    }
}

/// One FTP control connection, used by one operation at a time.
final class FTPControl: @unchecked Sendable {
    struct Reply {
        let code: Int
        let lines: [String]

        var text: String { lines.joined(separator: "\n").trimmingCharacters(in: .whitespaces) }
    }

    private let stream: FTPStream
    private let host: String
    private let session: URLSession
    private let trust: FTPTrust
    private(set) var usesTLS = false
    /// Whether data connections are encrypted too (PROT P).
    private var encryptsData = false
    private(set) var features: Set<String> = []
    private var supportsEPSV = true
    /// False during a transfer and after a connection error, when replies may be out of step.
    private(set) var isReusable = true
    var lastUsed = Date()

    private init(host: String, port: Int, session: URLSession, trust: FTPTrust) {
        self.host = host
        self.session = session
        self.trust = trust
        stream = FTPStream(session.streamTask(withHostName: host, port: port), trust: trust)
    }

    /// Connects and signs in, as "anonymous" if the user name is empty.
    static func open(source: NetworkSource, password: String, session: URLSession, trust: FTPTrust) async throws -> FTPControl {
        let control = FTPControl(host: source.hostName, port: source.port ?? 21, session: session, trust: trust)
        do {
            try await control.signIn(implicitTLS: source.usesImplicitTLS, user: source.username, password: password)
            return control
        } catch {
            control.close()
            throw error
        }
    }

    private func signIn(implicitTLS: Bool, user: String, password: String) async throws {
        if implicitTLS {
            stream.startTLS()
            usesTLS = true
        }
        var greeting = try await reply()
        while greeting.code == 120 { greeting = try await reply() } // "Ready in a few minutes"
        guard greeting.code == 220 else { throw RemoteError.connectionFailed(greeting.text) }
        if !implicitTLS, try await send("AUTH TLS").code == 234 {
            stream.startTLS()
            usesTLS = true
        }

        var login = try await send("USER \(user.isEmpty ? "anonymous" : user)")
        if login.code == 331 {
            login = try await send("PASS \(user.isEmpty && password.isEmpty ? "anonymous@" : password)")
        }
        switch login.code {
        case 230, 202: break
        case 530, 430: throw RemoteError.authenticationFailed
        case 332: throw RemoteError.unsupported("The server asks for an account, which FileCat doesn't support.")
        default: throw RemoteError.protocolError(login.text)
        }

        if usesTLS {
            // A server that turns down PROT P sends files unencrypted; the password still isn't.
            _ = try await send("PBSZ 0")
            encryptsData = try await send("PROT P").code == 200
        }
        let feat = try await send("FEAT")
        if feat.code == 211 {
            features = Set(feat.lines.dropFirst().compactMap {
                $0.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map { $0.uppercased() }
            })
        }
        if features.contains("UTF8") { _ = try await send("OPTS UTF8 ON") }
        let type = try await send("TYPE I")
        guard type.code == 200 else { throw FTPControl.error(for: type, name: "") }
    }

    func close() {
        isReusable = false
        stream.close()
    }

    // MARK: Commands

    func send(_ command: String) async throws -> Reply {
        do {
            try await stream.write(Data((command + "\r\n").utf8))
        } catch {
            isReusable = false
            throw error
        }
        return try await reply()
    }

    func reply() async throws -> Reply {
        do {
            let first = try await stream.readLine()
            guard let code = Int(first.prefix(3)), code >= 100 else {
                throw RemoteError.protocolError("This isn't an FTP server. Check the port.")
            }
            var lines = [String(first.dropFirst(4))]
            if first.dropFirst(3).first == "-" {
                while true {
                    let line = try await stream.readLine()
                    if line.hasPrefix("\(code) ") || line == "\(code)" {
                        lines.append(String(line.dropFirst(4)))
                        break
                    }
                    lines.append(line.hasPrefix("\(code)-") ? String(line.dropFirst(4)) : line)
                }
            }
            if code == 421 {
                isReusable = false
                throw RemoteError.connectionFailed(lines.joined(separator: " "))
            }
            return Reply(code: code, lines: lines)
        } catch {
            isReusable = false
            throw error
        }
    }

    /// Whether a file or folder exists at `path`.
    func exists(_ path: String) async throws -> Bool {
        if features.contains("MLST") { return try await send("MLST \(path)").code == 250 }
        if try await send("SIZE \(path)").code == 213 { return true }
        return try await send("CWD \(path)").code == 250
    }

    // MARK: Transfers

    /// Opens a passive-mode data connection, to the same host as the control connection.
    private func openData() async throws -> FTPStream {
        var port: Int?
        if supportsEPSV {
            let reply = try await send("EPSV")
            if reply.code == 229 { port = Self.extendedPassivePort(in: reply.text) }
            if port == nil { supportsEPSV = false }
        }
        if port == nil {
            let reply = try await send("PASV")
            guard reply.code == 227, let passive = Self.passivePort(in: reply.text) else {
                throw RemoteError.unsupported("The server doesn't support passive mode, which FileCat needs.")
            }
            port = passive
        }
        let data = FTPStream(session.streamTask(withHostName: host, port: port ?? 0), trust: trust)
        if encryptsData { data.startTLS() }
        return data
    }

    /// Starts a transfer with `command`, runs `body` with the data connection, then waits for
    /// the server to confirm. If `body` returns false the transfer was cut short and this
    /// connection can't be reused.
    private func transfer(_ command: String, name: String, setup: (() async throws -> Void)? = nil, _ body: (FTPStream) async throws -> Bool) async throws {
        let data = try await openData()
        defer { data.close() }
        try await setup?()
        let start = try await send(command)
        guard (100..<200).contains(start.code) else { throw Self.error(for: start, name: name) }
        isReusable = false
        guard try await body(data) else { return }
        data.close()
        let done = try await reply()
        guard (200..<300).contains(done.code) else { throw Self.error(for: done, name: name) }
        isReusable = true
    }

    /// Downloads from `offset`, handing the data to `receive` until it returns false.
    func retrieve(_ path: String, name: String, offset: Int64, receive: (Data) async throws -> Bool) async throws {
        try await transfer("RETR \(path)", name: name, setup: {
            guard offset > 0 else { return }
            let restart = try await self.send("REST \(offset)")
            guard restart.code == 350 else {
                throw RemoteError.unsupported("The server can't read files from the middle, which streaming needs.")
            }
        }) { data in
            while let chunk = try await data.read() {
                try Task.checkCancellation()
                if !chunk.isEmpty, !(try await receive(chunk)) { return false }
            }
            return true
        }
    }

    func store(_ path: String, name: String, from file: FileHandle, progress: @Sendable (Int64) -> Void) async throws {
        try await transfer("STOR \(path)", name: name) { data in
            var sent: Int64 = 0
            while let chunk = try file.read(upToCount: 256 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                try await data.write(chunk)
                sent += Int64(chunk.count)
                progress(sent)
            }
            data.finishWriting()
            return true
        }
    }

    /// The lines of a listing.
    func transferText(_ command: String, name: String) async throws -> [String] {
        var bytes = Data()
        try await transfer(command, name: name) { data in
            while let chunk = try await data.read() { bytes.append(chunk) }
            return true
        }
        let text = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1) ?? ""
        return text.split(whereSeparator: \.isNewline).map(String.init)
    }

    // MARK: Parsing

    /// "229 Entering Extended Passive Mode (|||6446|)"
    static func extendedPassivePort(in text: String) -> Int? {
        guard let open = text.firstIndex(of: "("), let close = text[open...].firstIndex(of: ")") else { return nil }
        let inside = text[text.index(after: open)..<close]
        guard let delimiter = inside.first else { return nil }
        let parts = inside.split(separator: delimiter, omittingEmptySubsequences: false)
        return parts.count >= 4 ? Int(parts[3]) : nil
    }

    /// "227 Entering Passive Mode (192,168,1,2,195,149)". The address is ignored: servers
    /// behind NAT often give one that can't be reached.
    static func passivePort(in text: String) -> Int? {
        let numbers = text.split { !$0.isNumber }.compactMap { Int($0) }
        guard numbers.count >= 6 else { return nil }
        let port = numbers.suffix(2)
        return port.first! * 256 + port.last!
    }

    /// `257 "/home/me" is the current directory`, with doubled quotes inside the path.
    static func quotedPath(in text: String) -> String? {
        guard let start = text.firstIndex(of: "\"") else { return nil }
        var path = ""
        var index = text.index(after: start)
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if character == "\"" {
                guard next < text.endIndex, text[next] == "\"" else { return path }
                index = text.index(after: next)
            } else {
                index = next
            }
            path.append(character)
        }
        return nil
    }

    static func error(for reply: Reply, name: String) -> RemoteError {
        let display = RemotePath.name(of: name).isEmpty ? "/" : RemotePath.name(of: name)
        let text = reply.text.lowercased()
        // vsftpd: "522 SSL connection failed: session reuse required". FileZilla Server: "425 Unable
        // to build data connection: TLS session of data connection not resumed."
        if (400..<600).contains(reply.code), text.contains("reuse") || text.contains("resum") {
            return .unsupported("The server requires file transfers to reuse its encrypted session, which iOS doesn't allow. Turn this off on the server (require_ssl_reuse=NO in vsftpd, or the TLS session resumption setting in FileZilla Server), or connect with SFTP instead.")
        }
        switch reply.code {
        case 530:
            return .accessDenied
        case 450, 550:
            if text.contains("denied") || text.contains("permission") { return .accessDenied }
            if ["no such", "not found", "not exist", "n't exist", "cannot find", "can't find", "failed to change directory"].contains(where: text.contains) {
                return .notFound(display)
            }
            return .protocolError(reply.text)
        case 552:
            return .unsupported("The server is out of space.")
        case 553:
            return .unsupported("The server doesn't allow this name.")
        case 425, 426:
            return .connectionFailed(reply.text)
        case 500, 502, 504:
            return .unsupported("The server doesn't support this (\(reply.text)).")
        default:
            return .protocolError(reply.text)
        }
    }
}

/// Reads the two listing formats: MLSD (RFC 3659), which is exact, and LIST, which is whatever
/// `ls -l` or Windows' `dir` print.
enum FTPListing {
    struct Item {
        let entry: RemoteEntry
        let isLink: Bool
    }

    /// "type=file;size=23;modify=20260102030405; hello.txt"
    static func parseMLSD(_ line: String) -> Item? {
        guard let space = line.firstIndex(of: " ") else { return nil }
        let name = String(line[line.index(after: space)...])
        var facts: [String: String] = [:]
        for fact in line[..<space].split(separator: ";") {
            let parts = fact.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { facts[parts[0].lowercased()] = String(parts[1]) }
        }
        let type = facts["type"]?.lowercased() ?? "file"
        guard type != "cdir", type != "pdir", !name.isEmpty else { return nil }
        let isDirectory = type == "dir"
        let modified = facts["modify"].flatMap { mlsdDate.date(from: String($0.prefix(14))) }
        return Item(
            entry: RemoteEntry(
                name: name, isDirectory: isDirectory,
                size: isDirectory ? nil : facts["size"].flatMap { Int64($0) }, modified: modified
            ),
            isLink: type.hasPrefix("os.unix=slink") || type.hasPrefix("os.unix=symlink")
        )
    }

    private static let unixPattern = try! NSRegularExpression(
        pattern: #"^([-dlbcps])\S{9}\S*\s+\d+\s+.+?\s+(\d+)\s+([A-Za-z]{3})\s+(\d{1,2})\s+(\d{1,2}:\d{2}|\d{4})\s(.+)$"#
    )
    private static let windowsPattern = try! NSRegularExpression(
        pattern: #"^(\d{2})-(\d{2})-(\d{2,4})\s+(\d{1,2}):(\d{2})\s*([AaPp][Mm])?\s+(<DIR>|\d+)\s+(.+)$"#
    )
    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    /// "-rw-r--r--   1 me  staff   23 Jan 10 12:34 hello.txt" or "01-10-26  12:34PM   23 hello.txt"
    static func parseLIST(_ line: String, now: Date = Date()) -> Item? {
        let range = NSRange(line.startIndex..., in: line)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        if let match = unixPattern.firstMatch(in: line, range: range) {
            func group(_ index: Int) -> String { Range(match.range(at: index), in: line).map { String(line[$0]) } ?? "" }
            let type = group(1)
            var name = group(6)
            if type == "l", let arrow = name.range(of: " -> ") { name = String(name[..<arrow.lowerBound]) }
            var components = DateComponents()
            components.month = (months.firstIndex(of: group(3).lowercased()) ?? 0) + 1
            components.day = Int(group(4))
            let timeOrYear = group(5)
            if timeOrYear.contains(":") {
                let parts = timeOrYear.split(separator: ":")
                components.hour = Int(parts[0])
                components.minute = Int(parts[1])
                // No year means within the last year.
                components.year = calendar.component(.year, from: now)
                if let date = calendar.date(from: components), date > now.addingTimeInterval(86400) {
                    components.year! -= 1
                }
            } else {
                components.year = Int(timeOrYear)
            }
            let isDirectory = type == "d"
            return Item(
                entry: RemoteEntry(name: name, isDirectory: isDirectory, size: isDirectory ? nil : Int64(group(2)), modified: calendar.date(from: components)),
                isLink: type == "l"
            )
        }
        if let match = windowsPattern.firstMatch(in: line, range: range) {
            func group(_ index: Int) -> String { Range(match.range(at: index), in: line).map { String(line[$0]) } ?? "" }
            var components = DateComponents()
            components.month = Int(group(1))
            components.day = Int(group(2))
            let year = Int(group(3)) ?? 1970
            components.year = year < 100 ? (year < 70 ? 2000 + year : 1900 + year) : year
            var hour = Int(group(4)) ?? 0
            let meridiem = group(6).lowercased()
            if meridiem == "pm", hour < 12 { hour += 12 }
            if meridiem == "am", hour == 12 { hour = 0 }
            components.hour = hour
            components.minute = Int(group(5))
            let isDirectory = group(7) == "<DIR>"
            return Item(
                entry: RemoteEntry(name: group(8), isDirectory: isDirectory, size: isDirectory ? nil : Int64(group(7)), modified: calendar.date(from: components)),
                isLink: false
            )
        }
        return nil
    }

    private static let mlsdDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter
    }()
}

/// A connection that can switch to TLS part way through, as AUTH TLS needs.
final class FTPStream: @unchecked Sendable {
    private let task: URLSessionStreamTask
    private let trust: FTPTrust
    private var buffer = Data()

    init(_ task: URLSessionStreamTask, trust: FTPTrust) {
        self.task = task
        self.trust = trust
        task.resume()
    }

    func startTLS() {
        task.startSecureConnection()
    }

    func write(_ data: Data) async throws {
        do {
            try await task.write(data, timeout: 60)
        } catch {
            throw describe(error)
        }
    }

    /// The next data that arrives; nil at the end.
    func read() async throws -> Data? {
        if !buffer.isEmpty {
            defer { buffer = Data() }
            return buffer
        }
        do {
            let (data, atEnd) = try await task.readData(ofMinLength: 1, maxLength: 256 * 1024, timeout: 60)
            if let data, !data.isEmpty { return data }
            return atEnd ? nil : Data()
        } catch {
            throw describe(error)
        }
    }

    func readLine() async throws -> String {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = Data(buffer[buffer.index(after: newline)...])
                let text = String(data: line, encoding: .utf8) ?? String(data: line, encoding: .isoLatin1) ?? ""
                return text.hasSuffix("\r") ? String(text.dropLast()) : text
            }
            guard buffer.count < 64 * 1024 else {
                throw RemoteError.protocolError("This isn't an FTP server. Check the port.")
            }
            let (data, atEnd) = try await { () async throws -> (Data?, Bool) in
                do {
                    return try await task.readData(ofMinLength: 1, maxLength: 4096, timeout: 60)
                } catch {
                    throw describe(error)
                }
            }()
            if let data { buffer.append(data) }
            if atEnd, data?.isEmpty ?? true {
                throw RemoteError.connectionFailed("The server closed the connection.")
            }
        }
    }

    /// Ends the upload, so the server sees the end of the file.
    func finishWriting() {
        task.closeWrite()
    }

    func close() {
        task.cancel()
    }

    private func describe(_ error: Error) -> Error {
        if let error = error as? URLError {
            switch error.code {
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid, .secureConnectionFailed, .cancelled:
                // Turning down a certificate cancels the connection.
                if let certificate = trust.untrustedCertificate {
                    return RemoteError.untrustedCertificate(fingerprint: certificate.fingerprint, summary: certificate.summary)
                }
                if error.code == .cancelled { return CancellationError() }
                return RemoteError.connectionFailed(error.localizedDescription)
            case .timedOut:
                return RemoteError.timedOut
            case .cannotConnectToHost:
                return RemoteError.connectionFailed("The server refused the connection. Check the address and port.")
            case .cannotFindHost, .dnsLookupFailed:
                return RemoteError.connectionFailed("The server name couldn't be found.")
            default:
                return RemoteError.connectionFailed(error.localizedDescription)
            }
        }
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain, error.code == Int(ECONNREFUSED) {
            return RemoteError.connectionFailed("The server refused the connection. Check the address and port.")
        }
        if let untrusted = trust.untrustedCertificate {
            return RemoteError.untrustedCertificate(fingerprint: untrusted.fingerprint, summary: untrusted.summary)
        }
        return RemoteError.connectionFailed(error.localizedDescription)
    }
}

/// Accepts certificates the system trusts, or the one the user chose to trust.
final class FTPTrust: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let trustedFingerprint: String?
    private let lock = NSLock()
    private var untrusted: (fingerprint: String, summary: String)?

    init(trustedFingerprint: String?) {
        self.trustedFingerprint = trustedFingerprint
    }

    /// The certificate of the last connection that failed validation, so the error can offer to trust it.
    var untrustedCertificate: (fingerprint: String, summary: String)? { lock.withLock { untrusted } }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        handle(challenge)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        handle(challenge)
    }

    private func handle(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = space.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        if SecTrustEvaluateWithError(trust, nil) { return (.performDefaultHandling, nil) }
        guard let certificate = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
            return (.performDefaultHandling, nil)
        }
        let fingerprint = WebDAVFileSystem.fingerprint(of: certificate)
        if fingerprint == trustedFingerprint {
            return (.useCredential, URLCredential(trust: trust))
        }
        let summary = SecCertificateCopySubjectSummary(certificate) as String? ?? space.host
        lock.withLock { untrusted = (fingerprint, summary) }
        return (.cancelAuthenticationChallenge, nil)
    }
}
