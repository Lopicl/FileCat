import CommonCrypto
import CryptoKit
import Foundation

/// NTLMv2 authentication (MS-NLMP), wrapped in SPNEGO for SMB session setup.
enum NTLM {
    static let signature = Data("NTLMSSP\0".utf8)

    private static let flags: UInt32 =
        0x0000_0001 // UNICODE
        | 0x0000_0004 // REQUEST_TARGET
        | 0x0000_0010 // SIGN
        | 0x0000_0200 // NTLM
        | 0x0000_8000 // ALWAYS_SIGN
        | 0x0008_0000 // EXTENDED_SESSIONSECURITY
        | 0x0080_0000 // TARGET_INFO
        | 0x2000_0000 // 128
        | 0x4000_0000 // KEY_EXCH
        | 0x8000_0000 // 56
    private static let anonymousFlag: UInt32 = 0x0000_0800
    private static let keyExchangeFlag: UInt32 = 0x4000_0000

    static func negotiateMessage() -> Data {
        var writer = ByteWriter()
        writer.bytes(signature)
        writer.u32(1)
        writer.u32(flags)
        writer.zeros(16) // Domain and workstation fields: empty.
        return writer.data
    }

    struct Challenge {
        let flags: UInt32
        let serverChallenge: Data
        let targetInfo: Data

        init(_ data: Data) throws {
            let reader = ByteReader(data)
            guard try reader.bytes(at: 0, count: 8) == NTLM.signature, try reader.u32(at: 8) == 2 else {
                throw RemoteError.protocolError("Unexpected sign-in challenge.")
            }
            flags = try reader.u32(at: 20)
            serverChallenge = try reader.bytes(at: 24, count: 8)
            let infoLength = Int(try reader.u16(at: 40))
            let infoOffset = Int(try reader.u32(at: 44))
            targetInfo = infoLength > 0 ? try reader.bytes(at: infoOffset, count: infoLength) : Data()
        }

        /// The server's clock from the target info, if it sent one (MsvAvTimestamp).
        var timestamp: Data? {
            var reader = ByteReader(targetInfo)
            while reader.remaining >= 4 {
                guard let id = try? reader.u16(), let length = try? reader.u16() else { return nil }
                if id == 0 { return nil }
                if id == 7, length == 8 { return try? reader.bytes(8) }
                try? reader.skip(Int(length))
            }
            return nil
        }
    }

    struct Authentication {
        let message: Data
        /// The key signing is derived from; all zeros for anonymous sign-in.
        let sessionKey: Data
    }

    static func authenticateMessage(challenge: Challenge, user: String, password: String, domain: String) -> Authentication {
        let anonymous = user.isEmpty && password.isEmpty
        var negotiated = flags & challenge.flags | 0x0000_0001
        var lmResponse = Data(count: 24)
        var ntResponse = Data()
        var sessionKey = Data(count: 16)
        var encryptedKey = Data()

        if anonymous {
            negotiated |= anonymousFlag
            negotiated &= ~keyExchangeFlag
            lmResponse = Data([0])
        } else {
            let ntHash = MD4.hash(password.utf16LittleEndian)
            let ntowf = hmacMD5(key: ntHash, data: (user.uppercased() + domain).utf16LittleEndian)
            let clientChallenge = randomBytes(8)
            let timestamp = challenge.timestamp ?? fileTime(Date())

            var blob = ByteWriter()
            blob.bytes([1, 1, 0, 0, 0, 0, 0, 0])
            blob.bytes(timestamp)
            blob.bytes(clientChallenge)
            blob.zeros(4)
            blob.bytes(challenge.targetInfo)
            blob.zeros(4)

            let proof = hmacMD5(key: ntowf, data: challenge.serverChallenge + blob.data)
            ntResponse = proof + blob.data
            let baseKey = hmacMD5(key: ntowf, data: proof)
            if challenge.flags & keyExchangeFlag != 0 {
                sessionKey = randomBytes(16)
                encryptedKey = rc4(key: baseKey, data: sessionKey)
            } else {
                sessionKey = baseKey
            }
        }

        let domainData = domain.utf16LittleEndian
        let userData = user.utf16LittleEndian
        let workstation = "FILECAT".utf16LittleEndian
        let payloads = [lmResponse, ntResponse, domainData, userData, workstation, encryptedKey]
        var offset = 64
        var offsets: [Int] = []
        for payload in payloads {
            offsets.append(offset)
            offset += payload.count
        }

        var writer = ByteWriter()
        writer.bytes(signature)
        writer.u32(3)
        for index in 0..<6 {
            writer.u16(UInt16(payloads[index].count))
            writer.u16(UInt16(payloads[index].count))
            writer.u32(UInt32(offsets[index]))
        }
        writer.u32(negotiated)
        for payload in payloads {
            writer.bytes(payload)
        }
        return Authentication(message: writer.data, sessionKey: sessionKey)
    }

    static func fileTime(_ date: Date) -> Data {
        var writer = ByteWriter()
        writer.u64(UInt64((date.timeIntervalSince1970 + 11_644_473_600) * 10_000_000))
        return writer.data
    }
}

/// Just enough ASN.1 DER to wrap NTLM in SPNEGO (RFC 4178).
enum SPNEGO {
    private static let spnegoOID: [UInt8] = [0x06, 0x06, 0x2B, 0x06, 0x01, 0x05, 0x05, 0x02]
    private static let ntlmOID: [UInt8] = [0x06, 0x0A, 0x2B, 0x06, 0x01, 0x04, 0x01, 0x82, 0x37, 0x02, 0x02, 0x0A]

    static func initialToken(_ mechToken: Data) -> Data {
        let mechTypes = tlv(0xA0, tlv(0x30, Data(ntlmOID)))
        let token = tlv(0xA2, tlv(0x04, mechToken))
        let negTokenInit = tlv(0xA0, tlv(0x30, mechTypes + token))
        return tlv(0x60, Data(spnegoOID) + negTokenInit)
    }

    static func responseToken(_ mechToken: Data) -> Data {
        tlv(0xA1, tlv(0x30, tlv(0xA2, tlv(0x04, mechToken))))
    }

    /// Finds the NTLM message inside the server's SPNEGO reply (or accepts a bare one).
    static func extractNTLM(_ data: Data) -> Data? {
        let data = Data(data)
        if data.starts(with: NTLM.signature) { return data }
        return findNTLM(in: data, range: 0..<data.count)
    }

    /// Walks DER elements looking for an OCTET STRING that holds an NTLM message.
    private static func findNTLM(in data: Data, range: Range<Int>) -> Data? {
        var index = range.lowerBound
        while index < range.upperBound {
            let tag = data[index]
            guard let (length, headerSize) = derLength(data, at: index + 1) else { return nil }
            let content = (index + 1 + headerSize)..<(index + 1 + headerSize + length)
            guard content.upperBound <= range.upperBound else { return nil }
            if tag == 0x04, data[content].starts(with: NTLM.signature) {
                return data.subdata(in: content)
            }
            // Constructed and context-specific elements contain more elements.
            if tag & 0x20 != 0, let found = findNTLM(in: data, range: content) {
                return found
            }
            index = content.upperBound
        }
        return nil
    }

    /// The length at `index` and how many bytes encode it.
    private static func derLength(_ data: Data, at index: Int) -> (Int, Int)? {
        guard index < data.count else { return nil }
        let first = data[index]
        if first < 0x80 { return (Int(first), 1) }
        let count = Int(first & 0x7F)
        guard count > 0, count <= 4, index + count < data.count else { return nil }
        let length = (1...count).reduce(0) { ($0 << 8) | Int(data[index + $1]) }
        return (length, count + 1)
    }

    private static func tlv(_ tag: UInt8, _ value: Data) -> Data {
        var data = Data([tag])
        let length = value.count
        if length < 0x80 {
            data.append(UInt8(length))
        } else if length <= 0xFF {
            data.append(contentsOf: [0x81, UInt8(length)])
        } else if length <= 0xFFFF {
            data.append(contentsOf: [0x82, UInt8(length >> 8), UInt8(length & 0xFF)])
        } else {
            data.append(contentsOf: [0x83, UInt8(length >> 16), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)])
        }
        return data + value
    }
}

// MARK: - Primitives

func randomBytes(_ count: Int) -> Data {
    var data = Data(count: count)
    _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
    return data
}

func hmacMD5(key: Data, data: Data) -> Data {
    var result = Data(count: Int(CC_MD5_DIGEST_LENGTH))
    result.withUnsafeMutableBytes { out in
        key.withUnsafeBytes { keyBytes in
            data.withUnsafeBytes { dataBytes in
                CCHmac(CCHmacAlgorithm(kCCHmacAlgMD5), keyBytes.baseAddress, key.count, dataBytes.baseAddress, data.count, out.baseAddress)
            }
        }
    }
    return result
}

func rc4(key: Data, data: Data) -> Data {
    crypt(CCOperation(kCCEncrypt), algorithm: CCAlgorithm(kCCAlgorithmRC4), options: 0, key: key, iv: nil, data: data)
}

private func crypt(_ operation: CCOperation, algorithm: CCAlgorithm, options: CCOptions, key: Data, iv: Data?, data: Data) -> Data {
    var output = Data(count: data.count + kCCBlockSizeAES128)
    var moved = 0
    let status = output.withUnsafeMutableBytes { out in
        key.withUnsafeBytes { keyBytes in
            data.withUnsafeBytes { dataBytes in
                (iv ?? Data()).withUnsafeBytes { ivBytes in
                    CCCrypt(operation, algorithm, options, keyBytes.baseAddress, key.count,
                            iv == nil ? nil : ivBytes.baseAddress, dataBytes.baseAddress, data.count,
                            out.baseAddress, out.count, &moved)
                }
            }
        }
    }
    guard status == kCCSuccess else { return Data() }
    return output.prefix(moved)
}

/// AES-128-CMAC (RFC 4493), used to sign SMB 3 messages.
func aesCMAC(key: Data, message: Data) -> Data {
    func shifted(_ block: Data) -> Data {
        var out = Data(count: 16)
        var carry: UInt8 = 0
        for index in stride(from: 15, through: 0, by: -1) {
            let byte = block[block.startIndex + index]
            out[index] = (byte << 1) | carry
            carry = byte >> 7
        }
        if block[block.startIndex] & 0x80 != 0 { out[15] ^= 0x87 }
        return out
    }
    func xor(_ a: Data, _ b: Data) -> Data {
        Data(zip(a, b).map { $0 ^ $1 })
    }
    let ecb = CCOptions(kCCOptionECBMode)
    let aes = CCAlgorithm(kCCAlgorithmAES)
    let l = crypt(CCOperation(kCCEncrypt), algorithm: aes, options: ecb, key: key, iv: nil, data: Data(count: 16))
    let k1 = shifted(l)
    let k2 = shifted(k1)

    let blockCount = max(1, (message.count + 15) / 16)
    let isComplete = !message.isEmpty && message.count % 16 == 0
    let lastStart = (blockCount - 1) * 16
    var last = message.subdata(in: message.startIndex + lastStart..<message.endIndex)
    if isComplete {
        last = xor(last, k1)
    } else {
        last.append(0x80)
        last.append(Data(count: 16 - last.count))
        last = xor(last, k2)
    }
    // CBC over every block but the last gives the running MAC state in one call.
    var state = Data(count: 16)
    if lastStart > 0 {
        let prefix = message.subdata(in: message.startIndex..<message.startIndex + lastStart)
        let chained = crypt(CCOperation(kCCEncrypt), algorithm: aes, options: 0, key: key, iv: Data(count: 16), data: prefix)
        state = chained.suffix(16)
    }
    return crypt(CCOperation(kCCEncrypt), algorithm: aes, options: ecb, key: key, iv: nil, data: xor(state, last))
}

/// SP800-108 counter-mode KDF with HMAC-SHA256, as SMB 3 uses it (L = 128).
func smbKDF(key: Data, label: Data, context: Data) -> Data {
    var input = ByteWriter()
    input.u32be(1)
    input.bytes(label)
    input.u8(0)
    input.bytes(context)
    input.u32be(128)
    let mac = HMAC<SHA256>.authenticationCode(for: input.data, using: SymmetricKey(data: key))
    return Data(mac).prefix(16)
}

/// MD4 (RFC 1320). Only used for the NT password hash.
enum MD4 {
    static func hash(_ message: Data) -> Data {
        var bytes = [UInt8](message)
        let bitLength = UInt64(bytes.count) * 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        withUnsafeBytes(of: bitLength.littleEndian) { bytes.append(contentsOf: $0) }

        var a: UInt32 = 0x6745_2301, b: UInt32 = 0xEFCD_AB89, c: UInt32 = 0x98BA_DCFE, d: UInt32 = 0x1032_5476
        func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }

        for chunk in stride(from: 0, to: bytes.count, by: 64) {
            var x = [UInt32](repeating: 0, count: 16)
            for index in 0..<16 {
                let base = chunk + index * 4
                x[index] = UInt32(bytes[base]) | UInt32(bytes[base + 1]) << 8 | UInt32(bytes[base + 2]) << 16 | UInt32(bytes[base + 3]) << 24
            }
            let (aa, bb, cc, dd) = (a, b, c, d)
            func f(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { (x & y) | (~x & z) }
            func g(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { (x & y) | (x & z) | (y & z) }
            func h(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { x ^ y ^ z }

            for index in [0, 4, 8, 12] {
                a = rotl(a &+ f(b, c, d) &+ x[index], 3)
                d = rotl(d &+ f(a, b, c) &+ x[index + 1], 7)
                c = rotl(c &+ f(d, a, b) &+ x[index + 2], 11)
                b = rotl(b &+ f(c, d, a) &+ x[index + 3], 19)
            }
            for index in 0..<4 {
                a = rotl(a &+ g(b, c, d) &+ x[index] &+ 0x5A82_7999, 3)
                d = rotl(d &+ g(a, b, c) &+ x[index + 4] &+ 0x5A82_7999, 5)
                c = rotl(c &+ g(d, a, b) &+ x[index + 8] &+ 0x5A82_7999, 9)
                b = rotl(b &+ g(c, d, a) &+ x[index + 12] &+ 0x5A82_7999, 13)
            }
            for index in [0, 2, 1, 3] {
                a = rotl(a &+ h(b, c, d) &+ x[index] &+ 0x6ED9_EBA1, 3)
                d = rotl(d &+ h(a, b, c) &+ x[index + 8] &+ 0x6ED9_EBA1, 9)
                c = rotl(c &+ h(d, a, b) &+ x[index + 4] &+ 0x6ED9_EBA1, 11)
                b = rotl(b &+ h(c, d, a) &+ x[index + 12] &+ 0x6ED9_EBA1, 15)
            }
            a = a &+ aa; b = b &+ bb; c = c &+ cc; d = d &+ dd
        }
        var out = ByteWriter()
        for word in [a, b, c, d] { out.u32(word) }
        return out.data
    }
}
