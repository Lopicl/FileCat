import Foundation

/// Nextcloud's Login Flow v2: the user signs in on the server's own page, and FileCat polls for
/// an app password. See https://docs.nextcloud.com/server/latest/developer_manual/client_apis/LoginFlow/
enum NextcloudLogin {
    struct Credentials: Decodable {
        let server: String
        let loginName: String
        let appPassword: String
    }

    struct Session: Identifiable {
        let id = UUID()
        let loginURL: URL
        fileprivate let token: String
        fileprivate let endpoint: URL

        /// Polls every two seconds until the user finishes signing in (up to 20 minutes).
        func waitForCompletion() async throws -> Credentials {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("token=\(token)".utf8)
            for _ in 0..<600 {
                try await Task.sleep(for: .seconds(2))
                guard let (data, response) = try? await URLSession.shared.data(for: request),
                      (response as? HTTPURLResponse)?.statusCode == 200
                else { continue }
                return try JSONDecoder().decode(Credentials.self, from: data)
            }
            throw RemoteError.timedOut
        }
    }

    private struct Start: Decodable {
        struct Poll: Decodable {
            let token: String
            let endpoint: String
        }
        let poll: Poll
        let login: String
    }

    static func start(server: String) async throws -> Session {
        var text = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text + "/index.php/login/v2") else {
            throw RemoteError.connectionFailed("The server address isn't valid.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("FileCat (iOS)", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw RemoteError.connectionFailed(error.localizedDescription)
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let start = try? JSONDecoder().decode(Start.self, from: data),
              let login = URL(string: start.login),
              let endpoint = URL(string: start.poll.endpoint)
        else {
            throw RemoteError.protocolError("This doesn't look like a Nextcloud server.")
        }
        return Session(loginURL: login, token: start.poll.token, endpoint: endpoint)
    }
}
