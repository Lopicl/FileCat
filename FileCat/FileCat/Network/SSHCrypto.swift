import CommonCrypto
import CryptoKit
import Foundation
import Security

// MARK: Wire format

/// SSH's data types (RFC 4251 section 5) on top of the big-endian `ByteWriter`/`ByteReader` calls.
extension ByteWriter {
    mutating func sshString(_ value: Data) {
        u32be(UInt32(value.count))
        bytes(value)
    }

    mutating func sshString(_ value: String) { sshString(Data(value.utf8)) }
    mutating func sshBool(_ value: Bool) { u8(value ? 1 : 0) }
    mutating func sshNameList(_ names: [String]) { sshString(names.joined(separator: ",")) }

    /// A non-negative `mpint`, given as big-endian bytes.
    mutating func sshMPInt(_ magnitude: Data) {
        var bytes = Data(magnitude.drop { $0 == 0 })
        if let first = bytes.first, first & 0x80 != 0 { bytes.insert(0, at: 0) }
        sshString(bytes)
    }
}

extension ByteReader {
    mutating func sshString() throws -> Data { try bytes(Int(try u32be())) }
    mutating func sshText() throws -> String { String(decoding: try sshString(), as: UTF8.self) }
    mutating func sshBool() throws -> Bool { try u8() != 0 }
    mutating func sshNameList() throws -> [String] { try sshText().split(separator: ",").map(String.init) }

    /// A non-negative `mpint`, left-padded with zeros to `length` bytes.
    mutating func sshMPInt(length: Int) throws -> Data {
        let value = Data(try sshString().drop { $0 == 0 })
        guard value.count <= length else { throw RemoteError.protocolError("A number from the server is too long.") }
        return Data(count: length - value.count) + value
    }
}

// MARK: Packet protection

/// Protects one direction of an SSH connection: the packet framing, encryption and MAC.
protocol SSHPacketCipher: AnyObject {
    var blockSize: Int { get }
    /// Whether the 4-byte length counts towards the block alignment of the padding.
    var alignsLength: Bool { get }
    /// Bytes to read before the packet length is known.
    var headerLength: Int { get }
    /// The tag or MAC that follows each packet.
    var trailerLength: Int { get }
    /// The packet as sent, for `body` (padding length, payload, padding).
    func seal(_ body: Data, sequence: UInt32) throws -> Data
    /// The packet length, from the first `headerLength` bytes.
    func packetLength(header: Data) throws -> Int
    /// The body, from the header, the rest of the packet and the trailer.
    func open(header: Data, rest: Data, trailer: Data, sequence: UInt32) throws -> Data
}

enum SSHCipherError {
    static var corrupted: RemoteError { .protocolError("A message from the server was corrupted.") }
}

/// Before the first key exchange: no encryption.
final class SSHPlainCipher: SSHPacketCipher {
    let blockSize = 8
    let alignsLength = true
    let headerLength = 4
    let trailerLength = 0

    func seal(_ body: Data, sequence: UInt32) throws -> Data {
        var writer = ByteWriter()
        writer.u32be(UInt32(body.count))
        writer.bytes(body)
        return writer.data
    }

    func packetLength(header: Data) throws -> Int { Int(try ByteReader(header).u32be(at: 0)) }

    func open(header: Data, rest: Data, trailer: Data, sequence: UInt32) throws -> Data { rest }
}

/// aes128-gcm@openssh.com and aes256-gcm@openssh.com (RFC 5647 as OpenSSH implements it):
/// the length is sent in the clear and authenticated with the rest.
final class SSHGCMCipher: SSHPacketCipher {
    let blockSize = 16
    let alignsLength = false
    let headerLength = 4
    let trailerLength = 16

    private let key: SymmetricKey
    private var nonce: [UInt8]

    init(key: Data, iv: Data) {
        self.key = SymmetricKey(data: key)
        nonce = Array(iv.prefix(12))
    }

    func seal(_ body: Data, sequence: UInt32) throws -> Data {
        var length = ByteWriter()
        length.u32be(UInt32(body.count))
        let box = try AES.GCM.seal(body, using: key, nonce: try AES.GCM.Nonce(data: nonce), authenticating: length.data)
        advance()
        return length.data + box.ciphertext + box.tag
    }

    func packetLength(header: Data) throws -> Int { Int(try ByteReader(header).u32be(at: 0)) }

    func open(header: Data, rest: Data, trailer: Data, sequence: UInt32) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: nonce), ciphertext: rest, tag: trailer)
            let body = try AES.GCM.open(box, using: key, authenticating: header)
            advance()
            return body
        } catch {
            throw SSHCipherError.corrupted
        }
    }

    /// The last 8 bytes of the nonce count packets.
    private func advance() {
        for index in stride(from: 11, through: 4, by: -1) {
            nonce[index] &+= 1
            if nonce[index] != 0 { break }
        }
    }
}

/// aes128-ctr, aes192-ctr and aes256-ctr with an HMAC-SHA2 MAC, computed over the plain packet
/// or, for the `-etm@openssh.com` MACs, over the encrypted one.
final class SSHCTRCipher: SSHPacketCipher {
    let blockSize = 16
    let alignsLength: Bool
    let headerLength: Int
    var trailerLength: Int { mac.length }

    private let cryptor: CCCryptorRef
    private let mac: SSHMAC
    private let encryptThenMAC: Bool
    /// The decrypted first block, which holds the length, until the rest of the packet arrives.
    private var firstBlock = Data()

    init(key: Data, iv: Data, mac: SSHMAC, encryptThenMAC: Bool) throws {
        var reference: CCCryptorRef?
        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                CCCryptorCreateWithMode(
                    CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                    ivBytes.baseAddress, keyBytes.baseAddress, key.count, nil, 0, 0,
                    CCModeOptions(kCCModeOptionCTR_BE), &reference
                )
            }
        }
        guard status == kCCSuccess, let reference else {
            throw RemoteError.protocolError("The encryption couldn't be set up.")
        }
        cryptor = reference
        self.mac = mac
        self.encryptThenMAC = encryptThenMAC
        alignsLength = !encryptThenMAC
        headerLength = encryptThenMAC ? 4 : 16
    }

    deinit {
        CCCryptorRelease(cryptor)
    }

    func seal(_ body: Data, sequence: UInt32) throws -> Data {
        var length = ByteWriter()
        length.u32be(UInt32(body.count))
        if encryptThenMAC {
            let encrypted = crypt(body)
            return length.data + encrypted + mac.code(sequence: sequence, length.data + encrypted)
        }
        let plain = length.data + body
        return crypt(plain) + mac.code(sequence: sequence, plain)
    }

    func packetLength(header: Data) throws -> Int {
        if encryptThenMAC { return Int(try ByteReader(header).u32be(at: 0)) }
        firstBlock = crypt(header)
        return Int(try ByteReader(firstBlock).u32be(at: 0))
    }

    func open(header: Data, rest: Data, trailer: Data, sequence: UInt32) throws -> Data {
        if encryptThenMAC {
            guard mac.matches(trailer, sequence: sequence, header + rest) else { throw SSHCipherError.corrupted }
            return crypt(rest)
        }
        let plain = firstBlock + crypt(rest)
        guard mac.matches(trailer, sequence: sequence, plain) else { throw SSHCipherError.corrupted }
        return plain.subdata(in: 4..<plain.count)
    }

    private func crypt(_ input: Data) -> Data {
        var output = Data(count: input.count)
        var moved = 0
        output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { inBytes in
                _ = CCCryptorUpdate(cryptor, inBytes.baseAddress, input.count, out.baseAddress, input.count, &moved)
            }
        }
        return output
    }
}

/// hmac-sha2-256 and hmac-sha2-512 over the sequence number and the packet.
struct SSHMAC {
    enum Hash { case sha256, sha512 }

    let hash: Hash
    let key: SymmetricKey

    var length: Int { hash == .sha256 ? 32 : 64 }

    func code(sequence: UInt32, _ data: Data) -> Data {
        var number = ByteWriter()
        number.u32be(sequence)
        switch hash {
        case .sha256:
            var hmac = HMAC<SHA256>(key: key)
            hmac.update(data: number.data)
            hmac.update(data: data)
            return Data(hmac.finalize())
        case .sha512:
            var hmac = HMAC<SHA512>(key: key)
            hmac.update(data: number.data)
            hmac.update(data: data)
            return Data(hmac.finalize())
        }
    }

    func matches(_ received: Data, sequence: UInt32, _ data: Data) -> Bool {
        let expected = code(sequence: sequence, data)
        guard received.count == expected.count else { return false }
        return zip(received, expected).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

// MARK: Algorithms

/// The algorithms FileCat offers, most preferred first.
enum SSHAlgorithms {
    static let keyExchange = [
        "curve25519-sha256", "curve25519-sha256@libssh.org",
        "ecdh-sha2-nistp256", "ecdh-sha2-nistp384", "ecdh-sha2-nistp521",
    ]
    static let hostKey = [
        "ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
        "rsa-sha2-512", "rsa-sha2-256", "ssh-rsa",
    ]
    static let ciphers = ["aes128-gcm@openssh.com", "aes256-gcm@openssh.com", "aes128-ctr", "aes192-ctr", "aes256-ctr"]
    static let macs = ["hmac-sha2-256-etm@openssh.com", "hmac-sha2-512-etm@openssh.com", "hmac-sha2-256", "hmac-sha2-512"]

    static func isAEAD(_ cipher: String) -> Bool { cipher.hasSuffix("-gcm@openssh.com") }

    /// Key and IV lengths.
    static func sizes(of cipher: String) -> (key: Int, iv: Int) {
        switch cipher {
        case "aes128-gcm@openssh.com": (16, 12)
        case "aes256-gcm@openssh.com": (32, 12)
        case "aes192-ctr": (24, 16)
        case "aes256-ctr": (32, 16)
        default: (16, 16)
        }
    }

    static func macKeyLength(of mac: String?) -> Int {
        mac?.hasPrefix("hmac-sha2-512") == true ? 64 : 32
    }

    static func makeCipher(_ cipher: String, mac: String?, key: Data, iv: Data, macKey: Data) throws -> any SSHPacketCipher {
        if isAEAD(cipher) { return SSHGCMCipher(key: key, iv: iv) }
        guard let mac else { throw RemoteError.protocolError("No MAC was agreed.") }
        let hash: SSHMAC.Hash = mac.hasPrefix("hmac-sha2-512") ? .sha512 : .sha256
        return try SSHCTRCipher(
            key: key, iv: iv, mac: SSHMAC(hash: hash, key: SymmetricKey(data: macKey)),
            encryptThenMAC: mac.hasSuffix("-etm@openssh.com")
        )
    }
}

/// The client's half of an elliptic-curve Diffie-Hellman exchange (RFC 5656, RFC 8731).
enum SSHEphemeralKey {
    case x25519(Curve25519.KeyAgreement.PrivateKey)
    case p256(P256.KeyAgreement.PrivateKey)
    case p384(P384.KeyAgreement.PrivateKey)
    case p521(P521.KeyAgreement.PrivateKey)

    init(for algorithm: String) {
        switch algorithm {
        case "ecdh-sha2-nistp256": self = .p256(P256.KeyAgreement.PrivateKey())
        case "ecdh-sha2-nistp384": self = .p384(P384.KeyAgreement.PrivateKey())
        case "ecdh-sha2-nistp521": self = .p521(P521.KeyAgreement.PrivateKey())
        default: self = .x25519(Curve25519.KeyAgreement.PrivateKey())
        }
    }

    var publicKey: Data {
        switch self {
        case .x25519(let key): key.publicKey.rawRepresentation
        case .p256(let key): key.publicKey.x963Representation
        case .p384(let key): key.publicKey.x963Representation
        case .p521(let key): key.publicKey.x963Representation
        }
    }

    /// The shared secret as big-endian bytes, to be sent as an `mpint`.
    func sharedSecret(with serverKey: Data) throws -> Data {
        do {
            let secret: SharedSecret = switch self {
            case .x25519(let key): try key.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: serverKey))
            case .p256(let key): try key.sharedSecretFromKeyAgreement(with: .init(x963Representation: serverKey))
            case .p384(let key): try key.sharedSecretFromKeyAgreement(with: .init(x963Representation: serverKey))
            case .p521(let key): try key.sharedSecretFromKeyAgreement(with: .init(x963Representation: serverKey))
            }
            let bytes = secret.withUnsafeBytes { Data($0) }
            guard bytes.contains(where: { $0 != 0 }) else { throw SSHCipherError.corrupted }
            return bytes
        } catch {
            throw RemoteError.protocolError("The server's key exchange value isn't valid.")
        }
    }

    func hash(_ data: Data) -> Data {
        switch self {
        case .x25519, .p256: Data(SHA256.hash(data: data))
        case .p384: Data(SHA384.hash(data: data))
        case .p521: Data(SHA512.hash(data: data))
        }
    }
}

// MARK: Host keys

enum SSHHostKey {
    /// OpenSSH's fingerprint format: "SHA256:" and unpadded Base64.
    static func fingerprint(of blob: Data) -> String {
        "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    /// "ED25519", "ECDSA" or "RSA".
    static func typeName(of blob: Data) -> String {
        var reader = ByteReader(blob)
        let type = (try? reader.sshText()) ?? ""
        if type == "ssh-ed25519" { return "ED25519" }
        if type.hasPrefix("ecdsa-") { return "ECDSA" }
        if type == "ssh-rsa" { return "RSA" }
        return type
    }

    /// Checks the server's signature of the exchange hash with its host key.
    static func verify(signature: Data, of hash: Data, blob: Data, algorithm: String) throws {
        var key = ByteReader(blob)
        var signatureReader = ByteReader(signature)
        let keyType = try key.sshText()
        let signatureType = try signatureReader.sshText()
        let signatureBytes = try signatureReader.sshString()
        guard signatureType == algorithm else { throw invalid }

        let valid: Bool
        switch algorithm {
        case "ssh-ed25519":
            guard keyType == algorithm else { throw invalid }
            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: try key.sshString())
            valid = publicKey.isValidSignature(signatureBytes, for: hash)
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            guard keyType == algorithm else { throw invalid }
            _ = try key.sshString() // Curve name
            let point = try key.sshString()
            var numbers = ByteReader(signatureBytes)
            switch algorithm {
            case "ecdsa-sha2-nistp256":
                let raw = try numbers.sshMPInt(length: 32) + numbers.sshMPInt(length: 32)
                valid = try P256.Signing.PublicKey(x963Representation: point)
                    .isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: raw), for: hash)
            case "ecdsa-sha2-nistp384":
                let raw = try numbers.sshMPInt(length: 48) + numbers.sshMPInt(length: 48)
                valid = try P384.Signing.PublicKey(x963Representation: point)
                    .isValidSignature(try P384.Signing.ECDSASignature(rawRepresentation: raw), for: hash)
            default:
                let raw = try numbers.sshMPInt(length: 66) + numbers.sshMPInt(length: 66)
                valid = try P521.Signing.PublicKey(x963Representation: point)
                    .isValidSignature(try P521.Signing.ECDSASignature(rawRepresentation: raw), for: hash)
            }
        case "rsa-sha2-256", "rsa-sha2-512", "ssh-rsa":
            guard keyType == "ssh-rsa" else { throw invalid }
            let exponent = Data(try key.sshString().drop { $0 == 0 })
            let modulus = Data(try key.sshString().drop { $0 == 0 })
            let der = DER.sequence(DER.integer(modulus) + DER.integer(exponent))
            let attributes: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            ]
            guard let publicKey = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil),
                  signatureBytes.count <= modulus.count
            else { throw invalid }
            let padded = Data(count: modulus.count - signatureBytes.count) + signatureBytes
            let secAlgorithm: SecKeyAlgorithm = switch algorithm {
            case "rsa-sha2-512": .rsaSignatureMessagePKCS1v15SHA512
            case "rsa-sha2-256": .rsaSignatureMessagePKCS1v15SHA256
            default: .rsaSignatureMessagePKCS1v15SHA1
            }
            valid = SecKeyVerifySignature(publicKey, secAlgorithm, hash as CFData, padded as CFData, nil)
        default:
            throw invalid
        }
        guard valid else { throw invalid }
    }

    private static var invalid: RemoteError {
        .protocolError("The server's identity couldn't be verified.")
    }
}

/// Just enough DER to describe an RSA public key (PKCS #1) to the Security framework.
enum DER {
    static func integer(_ magnitude: Data) -> Data {
        var content = magnitude.isEmpty ? Data([0]) : magnitude
        if content[content.startIndex] & 0x80 != 0 { content.insert(0, at: 0) }
        return Data([0x02]) + length(content.count) + content
    }

    static func sequence(_ content: Data) -> Data {
        Data([0x30]) + length(content.count) + content
    }

    private static func length(_ count: Int) -> Data {
        if count < 0x80 { return Data([UInt8(count)]) }
        var bytes: [UInt8] = []
        var remaining = count
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
}

// MARK: FileCat's own key

/// The Ed25519 key FileCat signs in with when a server accepts it, made on first use and kept
/// in the keychain. People add its public half to `~/.ssh/authorized_keys` on their servers.
enum SSHClientKey {
    private static let account = "ssh-client-key-ed25519"

    static func load() -> Curve25519.Signing.PrivateKey {
        if let stored = Keychain.password(for: account),
           let raw = Data(base64Encoded: stored),
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
            return key
        }
        let key = Curve25519.Signing.PrivateKey()
        Keychain.setPassword(key.rawRepresentation.base64EncodedString(), for: account)
        return key
    }

    static func publicKeyBlob(of key: Curve25519.Signing.PrivateKey) -> Data {
        var writer = ByteWriter()
        writer.sshString("ssh-ed25519")
        writer.sshString(key.publicKey.rawRepresentation)
        return writer.data
    }

    /// The line to add to `authorized_keys`.
    static func authorizedKeysLine(of key: Curve25519.Signing.PrivateKey) -> String {
        "ssh-ed25519 \(publicKeyBlob(of: key).base64EncodedString()) FileCat"
    }
}
