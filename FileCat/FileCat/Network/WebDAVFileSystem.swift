import CryptoKit
import Foundation

/// WebDAV (RFC 4918) over URLSession. Also used for Nextcloud, whose files live at
/// `/remote.php/dav/files/<user>/`.
final class WebDAVFileSystem: NSObject, RemoteFileSystem, URLSessionTaskDelegate, @unchecked Sendable {
    let baseURL: URL
    private let username: String
    private let password: String
    private let trustedFingerprint: String?
    private let alwaysSendsBasicAuth: Bool
    private var session: URLSession!

    private let lock = NSLock()
    /// Once the server asks for Basic auth, later requests send it up front to save a round trip.
    private var sendsBasicAuth: Bool
    /// The certificate of the last connection that failed validation, so the error can offer to trust it.
    private var untrustedCertificate: (fingerprint: String, summary: String)?

    init(source: NetworkSource, password: String) throws {
        guard let baseURL = source.webDAVBaseURL else {
            throw RemoteError.connectionFailed("The server address isn't valid.")
        }
        self.baseURL = baseURL
        username = source.username
        self.password = password
        trustedFingerprint = source.trustedCertificate
        // Sending the password up front is safe over HTTPS, and Nextcloud expects it.
        alwaysSendsBasicAuth = !source.username.isEmpty && (baseURL.scheme == "https" || source.kind == .nextcloud)
        sendsBasicAuth = alwaysSendsBasicAuth
        super.init()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60 * 60 * 6
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    // MARK: RemoteFileSystem

    func list(_ path: String) async throws -> [RemoteEntry] {
        var request = request(for: path, isDirectory: true, method: "PROPFIND")
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>
            """.utf8)
        let (data, response) = try await send(request)
        try check(response, path: path, expected: [207])

        let requestedPath = request.url.map(Self.decodedPath) ?? ""
        return WebDAVResponseParser.parse(data).compactMap { entry -> RemoteEntry? in
            let entryPath = Self.decodedPath(of: entry.href, relativeTo: baseURL)
            guard Self.trimmed(entryPath) != Self.trimmed(requestedPath) else { return nil }
            let name = RemotePath.name(of: entryPath)
            guard !name.isEmpty, !name.hasPrefix(".") else { return nil }
            return RemoteEntry(name: name, isDirectory: entry.isCollection, size: entry.isCollection ? nil : entry.size, modified: entry.modified)
        }
    }

    func read(_ path: String, offset: Int64, length: Int) async throws -> Data {
        var request = request(for: path, method: "GET")
        request.setValue("bytes=\(offset)-\(offset + Int64(length) - 1)", forHTTPHeaderField: "Range")
        let (data, response) = try await send(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 416 { return Data() }
        try check(response, path: path, expected: [200, 206])
        if status == 200 {
            // The server ignored the range and sent everything.
            let start = Int(min(offset, Int64(data.count)))
            return data.subdata(in: start..<min(data.count, start + length))
        }
        return data
    }

    func download(_ path: String, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let request = request(for: path, method: "GET")
        let observer = TaskProgressObserver(progress)
        let (location, response) = try await wrap { try await self.session.download(for: request, delegate: observer) }
        defer { try? FileManager.default.removeItem(at: location) }
        try check(response, path: path, expected: [200])
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: location, to: destination)
    }

    func upload(_ source: URL, to path: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        var request = request(for: path, method: "PUT")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let observer = TaskProgressObserver(progress, counting: .sent)
        let (_, response) = try await wrap { try await self.session.upload(for: request, fromFile: source, delegate: observer) }
        try check(response, path: path, expected: [200, 201, 204])
    }

    func createFolder(_ path: String) async throws {
        let (_, response) = try await send(request(for: path, isDirectory: true, method: "MKCOL"))
        if (response as? HTTPURLResponse)?.statusCode == 405 {
            throw RemoteError.alreadyExists(RemotePath.name(of: path))
        }
        try check(response, path: path, expected: [200, 201])
    }

    func delete(_ path: String, isDirectory: Bool) async throws {
        let (_, response) = try await send(request(for: path, isDirectory: isDirectory, method: "DELETE"))
        try check(response, path: path, expected: [200, 202, 204])
    }

    func move(_ path: String, to newPath: String) async throws {
        var request = request(for: path, method: "MOVE")
        request.setValue(url(for: newPath).absoluteString, forHTTPHeaderField: "Destination")
        request.setValue("F", forHTTPHeaderField: "Overwrite")
        let (_, response) = try await send(request)
        if (response as? HTTPURLResponse)?.statusCode == 412 {
            throw RemoteError.alreadyExists(RemotePath.name(of: newPath))
        }
        try check(response, path: path, expected: [200, 201, 204])
    }

    func close() async {
        session.invalidateAndCancel()
    }

    // MARK: Requests

    func url(for path: String, isDirectory: Bool = false) -> URL {
        var url = baseURL
        let components = RemotePath.components(of: path)
        for (index, component) in components.enumerated() {
            url.append(path: component, directoryHint: index == components.count - 1 && !isDirectory ? .notDirectory : .isDirectory)
        }
        return url
    }

    private func request(for path: String, isDirectory: Bool = false, method: String) -> URLRequest {
        var request = URLRequest(url: url(for: path, isDirectory: isDirectory))
        request.httpMethod = method
        request.setValue("FileCat (iOS)", forHTTPHeaderField: "User-Agent")
        if lock.withLock({ sendsBasicAuth }) {
            let token = Data("\(username):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await wrap { try await self.session.data(for: request) }
    }

    /// Turns URLSession errors into messages people can act on.
    private func wrap<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let error as URLError {
            switch error.code {
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid, .secureConnectionFailed:
                if let certificate = lock.withLock({ untrustedCertificate }) {
                    throw RemoteError.untrustedCertificate(fingerprint: certificate.fingerprint, summary: certificate.summary)
                }
                throw RemoteError.connectionFailed(error.localizedDescription)
            case .userAuthenticationRequired:
                throw RemoteError.authenticationFailed
            case .timedOut:
                throw RemoteError.timedOut
            case .cancelled:
                throw CancellationError()
            default:
                throw RemoteError.connectionFailed(error.localizedDescription)
            }
        }
    }

    private func check(_ response: URLResponse, path: String, expected: Set<Int>) throws {
        guard let http = response as? HTTPURLResponse else {
            throw RemoteError.protocolError("Not an HTTP response.")
        }
        if expected.contains(http.statusCode) { return }
        switch http.statusCode {
        case 401: throw RemoteError.authenticationFailed
        case 403: throw RemoteError.accessDenied
        case 404: throw RemoteError.notFound(RemotePath.name(of: path).isEmpty ? "/" : RemotePath.name(of: path))
        case 507: throw RemoteError.unsupported("The server is out of space.")
        case 207 where expected.contains(200):
            throw RemoteError.protocolError("Some items couldn't be changed.")
        default:
            if http.statusCode == 405 || http.statusCode == 501 {
                throw RemoteError.unsupported("The server doesn't allow this (HTTP \(http.statusCode)). Check that the address points to a WebDAV folder.")
            }
            throw RemoteError.protocolError("HTTP \(http.statusCode).")
        }
    }

    // MARK: URLSessionDelegate

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        handle(challenge)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        handle(challenge)
    }

    private func handle(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        switch space.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            guard let trust = space.serverTrust else { return (.performDefaultHandling, nil) }
            if SecTrustEvaluateWithError(trust, nil) { return (.performDefaultHandling, nil) }
            guard let certificate = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
                return (.performDefaultHandling, nil)
            }
            let fingerprint = Self.fingerprint(of: certificate)
            if fingerprint == trustedFingerprint {
                return (.useCredential, URLCredential(trust: trust))
            }
            let summary = SecCertificateCopySubjectSummary(certificate) as String? ?? space.host
            lock.withLock { untrustedCertificate = (fingerprint, summary) }
            return (.performDefaultHandling, nil)
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM:
            guard challenge.previousFailureCount == 0, !username.isEmpty else {
                // Let the 401 through so it's reported as a wrong password.
                return (.performDefaultHandling, nil)
            }
            if space.authenticationMethod == NSURLAuthenticationMethodHTTPBasic {
                lock.withLock { sendsBasicAuth = true }
            }
            return (.useCredential, URLCredential(user: username, password: password, persistence: .forSession))
        default:
            return (.performDefaultHandling, nil)
        }
    }

    static func fingerprint(of certificate: SecCertificate) -> String {
        let data = SecCertificateCopyData(certificate) as Data
        return SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    // MARK: Paths

    /// The percent-decoded path of an href, which may be a full URL or an absolute path.
    static func decodedPath(of href: String, relativeTo base: URL) -> String {
        let url = URL(string: href, relativeTo: base) ?? base
        return decodedPath(url)
    }

    static func decodedPath(_ url: URL) -> String {
        url.absoluteURL.path(percentEncoded: false)
    }

    private static func trimmed(_ path: String) -> String {
        path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

/// Reports a URLSession task's progress through a closure.
private final class TaskProgressObserver: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    enum Counting { case received, sent }

    private let handler: @Sendable (Int64) -> Void
    private let counting: Counting
    private var observation: NSKeyValueObservation?

    init(_ handler: @escaping @Sendable (Int64) -> Void, counting: Counting = .received) {
        self.handler = handler
        self.counting = counting
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let handler = handler
        switch counting {
        case .received:
            observation = task.observe(\.countOfBytesReceived) { task, _ in handler(task.countOfBytesReceived) }
        case .sent:
            observation = task.observe(\.countOfBytesSent) { task, _ in handler(task.countOfBytesSent) }
        }
    }
}

/// Reads a PROPFIND multistatus response.
final class WebDAVResponseParser: NSObject, XMLParserDelegate {
    struct Entry {
        var href = ""
        var isCollection = false
        var size: Int64?
        var modified: Date?
    }

    private var entries: [Entry] = []
    private var current: Entry?
    private var text = ""

    static func parse(_ data: Data) -> [Entry] {
        let delegate = WebDAVResponseParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        parser.parse()
        return delegate.entries
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        switch elementName {
        case "response": current = Entry()
        case "collection": current?.isCollection = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "href" where current?.href.isEmpty == true:
            current?.href = value
        case "getcontentlength":
            if let size = Int64(value) { current?.size = size }
        case "getlastmodified":
            if let date = Self.dateFormatter.date(from: value) { current?.modified = date }
        case "response":
            if let current { entries.append(current) }
            current = nil
        default:
            break
        }
        text = ""
    }
}
