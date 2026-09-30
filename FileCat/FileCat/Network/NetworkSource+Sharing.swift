import FileCatKit
import Foundation

/// Servers as companion apps see them (FileCatKit's `SharedServer`). MusiCat compiles this file
/// too, so both apps convert the same way.
extension NetworkSource {
    init?(shared: SharedServer) {
        guard let kind = Kind(rawValue: shared.kind) else { return nil }
        self.init(
            id: shared.id, kind: kind, name: shared.name, host: shared.host, port: shared.port,
            path: shared.path, username: shared.username, domain: shared.domain,
            uid: shared.uid, gid: shared.gid, trustedCertificate: shared.trustedCertificate,
            passwordChanged: shared.passwordChanged
        )
    }

    var shared: SharedServer {
        SharedServer(
            id: id, kind: kind.rawValue, name: name, host: host, port: port, path: path,
            username: username, domain: domain, uid: uid, gid: gid,
            trustedCertificate: trustedCertificate, passwordChanged: passwordChanged
        )
    }
}
