import SafariServices
import SwiftUI

/// Adds or edits a server. Saving connects first, so mistakes show up right away.
struct ServerEditorView: View {
    let request: ServerEditorRequest

    @Environment(SourceStore.self) private var sources
    @Environment(\.dismiss) private var dismiss

    @State private var source: NetworkSource
    @State private var password = ""
    @State private var portText = ""
    @State private var uidText = ""
    @State private var gidText = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @State private var untrusted: (fingerprint: String, summary: String)?
    @State private var hostKey: (fingerprint: String, keyType: String, changed: Bool)?
    @State private var copiedKey = false
    @State private var shares: [String]?
    @State private var isLoadingShares = false
    @State private var nextcloudLogin: NextcloudLogin.Session?
    @State private var loginTask: Task<Void, Never>?
    @State private var isWaitingForLogin = false

    init(request: ServerEditorRequest) {
        self.request = request
        _source = State(initialValue: request.source)
        _portText = State(initialValue: request.source.port.map(String.init) ?? "")
        _uidText = State(initialValue: request.source.uid.map(String.init) ?? "")
        _gidText = State(initialValue: request.source.gid.map(String.init) ?? "")
    }

    private var kind: NetworkSource.Kind { source.kind }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(hostPrompt, text: $source.host)
                        .keyboardType(kind == .webdav || kind == .nextcloud ? .URL : .asciiCapable)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("serverHost")
                    TextField("Name (Optional)", text: $source.name)
                        .accessibilityIdentifier("serverName")
                } header: {
                    Text(kind == .webdav || kind == .nextcloud ? "Server Address" : "Server")
                } footer: {
                    Text(hostFooter)
                }

                if kind == .smb || kind == .nfs {
                    shareSection
                }

                if kind == .nextcloud {
                    nextcloudSection
                }

                if kind == .sftp || kind == .ftp {
                    folderSection
                }

                if kind != .nfs {
                    Section {
                        TextField(kind == .nextcloud ? "Login Name" : "User Name", text: $source.username)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .accessibilityIdentifier("serverUser")
                        SecureField(passwordPrompt, text: $password)
                            .accessibilityIdentifier("serverPassword")
                    } header: {
                        Text(kind == .nextcloud ? "Or Use an App Password" : "Account")
                    } footer: {
                        Text(accountFooter)
                    }
                }

                if kind == .sftp {
                    sshKeySection
                }

                Section("Advanced") {
                    TextField("Port (\(kind == .nfs ? "ask the server" : String(defaultPort)))", text: $portText)
                        .keyboardType(.numberPad)
                    if kind == .smb {
                        TextField("Domain (Optional)", text: $source.domain)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    if kind == .nfs {
                        TextField("User ID (1000)", text: $uidText)
                            .keyboardType(.numberPad)
                        TextField("Group ID (1000)", text: $gidText)
                            .keyboardType(.numberPad)
                    }
                    if source.trustedCertificate != nil {
                        Button(kind == .sftp ? "Forget Server Key" : "Stop Trusting Certificate", role: .destructive) {
                            source.trustedCertificate = nil
                        }
                    }
                }
            }
            .navigationTitle(request.isNew ? kind.title : source.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isConnecting {
                        ProgressView()
                    } else {
                        Button(request.isNew ? "Connect" : "Save") { Task { await save() } }
                            .disabled(source.host.trimmingCharacters(in: .whitespaces).isEmpty)
                            .accessibilityIdentifier("saveServer")
                    }
                }
            }
            .alert("Couldn't Connect", isPresented: Binding(isPresenting: $errorMessage), presenting: errorMessage) { _ in
                Button("OK") {}
            } message: { message in
                Text(message)
            }
            .alert("Trust This Certificate?", isPresented: Binding(isPresenting: Binding(
                get: { untrusted.map { _ in true } },
                set: { if $0 == nil { untrusted = nil } }
            ))) {
                Button("Trust and Connect") {
                    source.trustedCertificate = untrusted?.fingerprint
                    untrusted = nil
                    Task { await save() }
                }
                Button("Cancel", role: .cancel) { untrusted = nil }
            } message: {
                Text("“\(untrusted?.summary ?? "")” isn't signed by a trusted authority. This is normal for NAS devices and home servers with their own certificate. Only continue if this is your server.\n\nSHA-256: \(untrusted?.fingerprint ?? "")")
            }
            .alert(hostKey?.changed == true ? "Server Identity Changed" : "Trust This Server?", isPresented: Binding(isPresenting: Binding(
                get: { hostKey.map { _ in true } },
                set: { if $0 == nil { hostKey = nil } }
            ))) {
                Button(hostKey?.changed == true ? "Trust New Key" : "Trust and Connect", role: hostKey?.changed == true ? .destructive : nil) {
                    source.trustedCertificate = hostKey?.fingerprint
                    hostKey = nil
                    Task { await save() }
                }
                Button("Cancel", role: .cancel) { hostKey = nil }
            } message: {
                if hostKey?.changed == true {
                    Text("The key of “\(edited.hostName)” isn't the one you trusted before. That's expected after reinstalling or replacing the server, but it can also mean someone is intercepting the connection.\n\nNew \(hostKey?.keyType ?? "") key:\n\(hostKey?.fingerprint ?? "")")
                } else {
                    Text("FileCat hasn't connected to “\(edited.hostName)” before. To be sure it's your server, check that its key matches (ssh-keygen -lf on the server shows it).\n\n\(hostKey?.keyType ?? "") key:\n\(hostKey?.fingerprint ?? "")")
                }
            }
            .sheet(item: $nextcloudLogin, onDismiss: {
                // Closing the sign-in page before finishing stops waiting for it.
                if isWaitingForLogin { loginTask?.cancel() }
            }) { session in
                SafariView(url: session.loginURL)
                    .ignoresSafeArea()
            }
        }
        .interactiveDismissDisabled(isConnecting)
        // A different server has a different key or certificate.
        .onChange(of: source.host) { forgetTrustedServer() }
        .onChange(of: portText) { forgetTrustedServer() }
    }

    // MARK: Sections

    @ViewBuilder
    private var shareSection: some View {
        Section {
            HStack {
                TextField(kind == .smb ? "Share (e.g. Media or Media/Music)" : "Export Path (e.g. /volume1/media)", text: $source.path)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("serverShare")
                if isLoadingShares {
                    ProgressView()
                } else {
                    Button("Browse") { Task { await loadShares() } }
                        .disabled(source.host.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if let shares {
                if shares.isEmpty {
                    Text(kind == .smb ? "No shares found." : "No exports found.")
                        .foregroundStyle(.secondary)
                }
                ForEach(shares, id: \.self) { share in
                    Button {
                        source.path = share
                        self.shares = nil
                    } label: {
                        Label(share, systemImage: "externaldrive.connected.to.line.below")
                    }
                    .tint(.primary)
                }
            }
        } header: {
            Text(kind == .smb ? "Share" : "Export")
        } footer: {
            Text(kind == .smb
                 ? "Leave empty to pick a share after connecting."
                 : "The server must allow connections from unprivileged ports (the “insecure” export option), because iOS apps can't use ports below 1024.")
        }
    }

    private var folderSection: some View {
        Section {
            TextField(kind == .sftp ? "Folder (e.g. /volume1/media)" : "Folder (e.g. /pub)", text: $source.path)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("serverFolder")
        } header: {
            Text("Folder")
        } footer: {
            Text(kind == .sftp
                 ? "Optional. Leave empty to start in your home folder."
                 : "Optional. Leave empty to start in the folder the server opens.")
        }
    }

    private var sshKeySection: some View {
        Section {
            Button {
                UIPasteboard.general.string = SSHClientKey.authorizedKeysLine(of: SSHClientKey.load())
                copiedKey = true
            } label: {
                Label(copiedKey ? "Copied" : "Copy FileCat's Public Key", systemImage: copiedKey ? "checkmark" : "key")
            }
            .accessibilityIdentifier("copySSHKey")
        } header: {
            Text("SSH Key")
        } footer: {
            Text("To sign in without a password, add this key to ~/.ssh/authorized_keys on the server. FileCat tries it before the password.")
        }
    }

    @ViewBuilder
    private var nextcloudSection: some View {
        Section {
            Button {
                loginTask = Task { await startNextcloudLogin() }
            } label: {
                Label(source.username.isEmpty ? "Sign In with Nextcloud…" : "Signed in as \(source.username) — Sign In Again…", systemImage: "person.badge.key")
            }
            .disabled(source.host.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityIdentifier("nextcloudSignIn")
        } footer: {
            Text("Opens your Nextcloud's sign-in page. FileCat gets its own app password, which you can revoke in Nextcloud's security settings.")
        }
    }

    // MARK: Text

    private var defaultPort: Int {
        if kind == .webdav || kind == .nextcloud {
            return source.host.lowercased().hasPrefix("http://") ? 80 : 443
        }
        return kind.defaultPort
    }

    private var hostPrompt: String {
        switch kind {
        case .smb, .nfs, .sftp, .ftp: "Host Name or IP Address"
        case .webdav: "https://example.com/dav/"
        case .nextcloud: "https://cloud.example.com"
        }
    }

    private var hostFooter: String {
        switch kind {
        case .smb: "For example nas.local or 192.168.1.20."
        case .nfs: "FileCat uses NFS version 3 over TCP."
        case .webdav: "The full address of the WebDAV folder. Addresses starting with http:// aren't encrypted."
        case .nextcloud: "The address you use to open Nextcloud in a browser."
        case .sftp: "For example nas.local or 192.168.1.20: the address you'd use with ssh."
        case .ftp: "For example nas.local or ftp.example.com. FileCat encrypts the connection when the server supports it (FTPS). For servers with implicit TLS, start with ftps://."
        }
    }

    private var passwordPrompt: String {
        if !request.isNew && password.isEmpty { return "Password (Unchanged)" }
        return kind == .nextcloud ? "App Password" : "Password"
    }

    private var accountFooter: String {
        switch kind {
        case .smb: "Leave both empty to connect as a guest."
        case .ftp: "Leave both empty to sign in anonymously."
        case .nextcloud: "Create an app password in Nextcloud under Settings → Security if you'd rather not sign in above."
        default: ""
        }
    }

    // MARK: Actions

    /// The source with the text fields applied.
    private var edited: NetworkSource {
        var source = source
        source.host = source.host.trimmingCharacters(in: .whitespacesAndNewlines)
        source.path = source.path.trimmingCharacters(in: .whitespacesAndNewlines)
        source.username = source.username.trimmingCharacters(in: .whitespacesAndNewlines)
        source.port = Int(portText)
        source.uid = Int(uidText)
        source.gid = Int(gidText)
        if source.name.trimmingCharacters(in: .whitespaces).isEmpty {
            source.name = Self.defaultName(for: source)
        }
        return source
    }

    private func forgetTrustedServer() {
        if kind == .sftp || kind == .ftp { source.trustedCertificate = nil }
    }

    private var effectivePassword: String {
        !request.isNew && password.isEmpty ? request.source.password : password
    }

    private func save() async {
        let source = edited
        isConnecting = true
        defer { isConnecting = false }
        do {
            let fileSystem = try await RemoteConnections.connect(source, password: effectivePassword)
            await fileSystem.close()
            sources.save(source, password: request.isNew || !password.isEmpty ? password : nil)
            dismiss()
        } catch RemoteError.untrustedCertificate(let fingerprint, let summary) {
            untrusted = (fingerprint, summary)
        } catch RemoteError.untrustedHostKey(let fingerprint, let keyType, let changed) {
            hostKey = (fingerprint, keyType, changed)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadShares() async {
        isLoadingShares = true
        defer { isLoadingShares = false }
        do {
            let source = edited
            shares = switch kind {
            case .smb: try await SMBFileSystem.listShares(source: source, password: effectivePassword)
            case .nfs: try await NFSFileSystem.listExports(source: source)
            default: []
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startNextcloudLogin() async {
        do {
            let session = try await NextcloudLogin.start(server: edited.host)
            nextcloudLogin = session
            isWaitingForLogin = true
            defer { isWaitingForLogin = false }
            let result = try await session.waitForCompletion()
            isWaitingForLogin = false
            nextcloudLogin = nil
            source.host = result.server
            source.username = result.loginName
            password = result.appPassword
            await save()
        } catch is CancellationError {
            nextcloudLogin = nil
        } catch {
            nextcloudLogin = nil
            errorMessage = error.localizedDescription
        }
    }

    static func defaultName(for source: NetworkSource) -> String {
        switch source.kind {
        case .smb:
            let share = RemotePath.components(of: source.path).last
            return share.map { "\($0) on \(source.host)" } ?? source.host
        case .nfs:
            return "\(source.host):\(source.path.isEmpty ? "/" : source.path)"
        case .webdav, .nextcloud:
            return URLComponents(string: source.host.contains("://") ? source.host : "https://" + source.host)?.host ?? source.host
        case .sftp, .ftp:
            let folder = RemotePath.components(of: source.path).last
            return folder.map { "\($0) on \(source.hostName)" } ?? source.hostName
        }
    }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
