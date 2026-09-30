import Foundation
import Network
import Observation

/// Finds file servers on the local network that advertise themselves with Bonjour.
@MainActor
@Observable
final class ServiceDiscovery {
    struct Service: Identifiable, Hashable {
        let name: String
        let kind: NetworkSource.Kind
        let endpoint: NWEndpoint
        let usesTLS: Bool

        var id: String { "\(kind.rawValue)|\(name)|\(usesTLS)" }

        /// A new source for this server. The host is filled in by `resolved()`.
        func draft(host: String, port: Int?) -> NetworkSource {
            var source = NetworkSource(kind: kind, name: name, host: host)
            switch kind {
            case .webdav, .nextcloud:
                let scheme = usesTLS ? "https" : "http"
                let defaultPort = usesTLS ? 443 : 80
                source.host = "\(scheme)://\(host)\(port.map { $0 == defaultPort ? "" : ":\($0)" } ?? "")/"
            case .smb, .nfs:
                if let port, port != kind.defaultPort { source.port = port }
            }
            return source
        }

        /// Looks up the server's address.
        func resolved() async -> NetworkSource {
            let fallback = draft(host: Self.hostName(from: name), port: nil)
            let parameters = NWParameters.tcp
            if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                ip.version = .v4
            }
            let connection = NWConnection(to: endpoint, using: parameters)
            let result: NetworkSource = await withCheckedContinuation { continuation in
                let once = Once()
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if case .hostPort(let host, let port) = connection.currentPath?.remoteEndpoint {
                            var text = "\(host)"
                            if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
                            once.run { continuation.resume(returning: draft(host: text, port: Int(port.rawValue))) }
                        } else {
                            once.run { continuation.resume(returning: fallback) }
                        }
                        connection.cancel()
                    case .failed, .cancelled:
                        once.run { continuation.resume(returning: fallback) }
                    default:
                        break
                    }
                }
                connection.start(queue: .main)
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    once.run { continuation.resume(returning: fallback) }
                    connection.cancel()
                }
            }
            return result
        }

        private static func hostName(from name: String) -> String {
            name.replacingOccurrences(of: " ", with: "-") + ".local"
        }
    }

    private(set) var services: [Service] = []
    @ObservationIgnored private var browsers: [NWBrowser] = []

    private static let types: [(type: String, kind: NetworkSource.Kind, tls: Bool)] = [
        ("_smb._tcp", .smb, false),
        ("_nfs._tcp", .nfs, false),
        ("_webdav._tcp", .webdav, false),
        ("_webdavs._tcp", .webdav, true),
    ]

    func start() {
        guard browsers.isEmpty else { return }
        for entry in Self.types {
            let browser = NWBrowser(for: .bonjour(type: entry.type, domain: nil), using: .tcp)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                let found = results.compactMap { result -> Service? in
                    guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                    return Service(name: name, kind: entry.kind, endpoint: result.endpoint, usesTLS: entry.tls)
                }
                MainActor.assumeIsolated {
                    self?.update(found, kind: entry.kind, tls: entry.tls)
                }
            }
            browser.start(queue: .main)
            browsers.append(browser)
        }
    }

    func stop() {
        browsers.forEach { $0.cancel() }
        browsers = []
    }

    private func update(_ found: [Service], kind: NetworkSource.Kind, tls: Bool) {
        services.removeAll { $0.kind == kind && $0.usesTLS == tls }
        services += found
        services.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
