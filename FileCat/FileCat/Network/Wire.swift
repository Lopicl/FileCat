import Foundation
import Network

/// Builds binary messages. Little-endian by default (SMB); the `be` variants are for XDR (NFS).
struct ByteWriter {
    private(set) var data = Data()

    var count: Int { data.count }

    init() {}

    mutating func u8(_ value: UInt8) { data.append(value) }
    mutating func u16(_ value: UInt16) { append(value.littleEndian) }
    mutating func u32(_ value: UInt32) { append(value.littleEndian) }
    mutating func u64(_ value: UInt64) { append(value.littleEndian) }
    mutating func u32be(_ value: UInt32) { append(value.bigEndian) }
    mutating func u64be(_ value: UInt64) { append(value.bigEndian) }
    mutating func bytes(_ bytes: Data) { data.append(bytes) }
    mutating func bytes(_ bytes: [UInt8]) { data.append(contentsOf: bytes) }
    mutating func zeros(_ count: Int) { data.append(Data(count: count)) }

    /// Pads with zeros until the length is a multiple of `boundary`.
    mutating func align(_ boundary: Int) {
        let remainder = data.count % boundary
        if remainder != 0 { zeros(boundary - remainder) }
    }

    mutating func set16(_ value: UInt16, at offset: Int) { set(value.littleEndian, at: offset) }
    mutating func set32(_ value: UInt32, at offset: Int) { set(value.littleEndian, at: offset) }
    mutating func set32be(_ value: UInt32, at offset: Int) { set(value.bigEndian, at: offset) }

    private mutating func append<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
    }

    private mutating func set<T: FixedWidthInteger>(_ value: T, at offset: Int) {
        withUnsafeBytes(of: value) { data.replaceSubrange(offset..<offset + MemoryLayout<T>.size, with: $0) }
    }
}

enum WireError: Error {
    case truncated
}

/// Reads binary messages. Offsets are relative to the start of `data`.
struct ByteReader {
    let data: Data
    var offset = 0

    init(_ data: Data, offset: Int = 0) {
        // Rebase so indices start at zero, whatever slice we were given.
        self.data = Data(data)
        self.offset = offset
    }

    var remaining: Int { data.count - offset }

    func u8(at position: Int) throws -> UInt8 {
        guard position >= 0, position < data.count else { throw WireError.truncated }
        return data[position]
    }

    func u16(at position: Int) throws -> UInt16 { UInt16(littleEndian: try value(at: position)) }
    func u32(at position: Int) throws -> UInt32 { UInt32(littleEndian: try value(at: position)) }
    func u64(at position: Int) throws -> UInt64 { UInt64(littleEndian: try value(at: position)) }
    func u32be(at position: Int) throws -> UInt32 { UInt32(bigEndian: try value(at: position)) }
    func u64be(at position: Int) throws -> UInt64 { UInt64(bigEndian: try value(at: position)) }

    func bytes(at position: Int, count: Int) throws -> Data {
        guard position >= 0, count >= 0, position + count <= data.count else { throw WireError.truncated }
        return data.subdata(in: position..<position + count)
    }

    mutating func u8() throws -> UInt8 { defer { offset += 1 }; return try u8(at: offset) }
    mutating func u16() throws -> UInt16 { defer { offset += 2 }; return try u16(at: offset) }
    mutating func u32() throws -> UInt32 { defer { offset += 4 }; return try u32(at: offset) }
    mutating func u64() throws -> UInt64 { defer { offset += 8 }; return try u64(at: offset) }
    mutating func u32be() throws -> UInt32 { defer { offset += 4 }; return try u32be(at: offset) }
    mutating func u64be() throws -> UInt64 { defer { offset += 8 }; return try u64be(at: offset) }

    mutating func bytes(_ count: Int) throws -> Data {
        defer { offset += count }
        return try bytes(at: offset, count: count)
    }

    mutating func skip(_ count: Int) throws {
        guard offset + count <= data.count else { throw WireError.truncated }
        offset += count
    }

    mutating func align(_ boundary: Int) {
        let remainder = offset % boundary
        if remainder != 0 { offset += boundary - remainder }
    }

    private func value<T: FixedWidthInteger>(at position: Int) throws -> T {
        let size = MemoryLayout<T>.size
        guard position >= 0, position + size <= data.count else { throw WireError.truncated }
        var value: T = 0
        withUnsafeMutableBytes(of: &value) { buffer in
            data.copyBytes(to: buffer.bindMemory(to: UInt8.self), from: position..<position + size)
        }
        return value
    }
}

extension String {
    var utf16LittleEndian: Data {
        var data = Data(capacity: utf16.count * 2)
        for unit in utf16 {
            data.append(UInt8(unit & 0xFF))
            data.append(UInt8(unit >> 8))
        }
        return data
    }

    init(utf16LittleEndian data: Data) {
        let units = stride(from: 0, to: data.count - 1, by: 2).map {
            UInt16(data[data.startIndex + $0]) | UInt16(data[data.startIndex + $0 + 1]) << 8
        }
        self = String(decoding: units, as: UTF16.self)
    }
}

/// A TCP connection with async send and receive, built on Network.framework.
final class TCPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "FileCat.TCPConnection")

    init(host: String, port: UInt16) {
        let options = NWProtocolTCP.Options()
        options.noDelay = true
        options.enableKeepalive = true
        options.keepaliveIdle = 30
        options.connectionTimeout = 10
        let parameters = NWParameters(tls: nil, tcp: options)
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 445, using: parameters)
    }

    func open() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once()
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    once.run { continuation.resume() }
                case .failed(let error):
                    once.run { continuation.resume(throwing: RemoteError.connectionFailed(Self.describe(error))) }
                case .waiting(let error):
                    // No route (wrong address, server off): fail fast instead of waiting forever.
                    once.run { continuation.resume(throwing: RemoteError.connectionFailed(Self.describe(error))) }
                    self?.connection.cancel()
                case .cancelled:
                    once.run { continuation.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 12) { [weak self] in
                once.run { continuation.resume(throwing: RemoteError.timedOut) }
                self?.connection.cancel()
            }
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: RemoteError.connectionFailed(Self.describe(error)))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Waits for exactly `count` bytes.
    func receive(exactly count: Int) async throws -> Data {
        var buffer = Data(capacity: count)
        while buffer.count < count {
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: count - buffer.count) { content, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: RemoteError.connectionFailed(Self.describe(error)))
                    } else if let content, !content.isEmpty {
                        continuation.resume(returning: content)
                    } else if isComplete {
                        continuation.resume(throwing: RemoteError.connectionFailed("The server closed the connection."))
                    } else {
                        continuation.resume(returning: Data())
                    }
                }
            }
            buffer.append(chunk)
        }
        return buffer
    }

    func close() {
        connection.cancel()
    }

    private static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code) where code == .ECONNREFUSED:
            return "The server refused the connection. Check the address and port."
        case .posix(let code) where code == .ETIMEDOUT || code == .EHOSTUNREACH || code == .ENETUNREACH:
            return "The server can't be reached."
        case .dns:
            return "The server name couldn't be found."
        default:
            return error.localizedDescription
        }
    }
}

/// Runs a closure at most once, from any thread.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        guard !done else {
            lock.unlock()
            return
        }
        done = true
        lock.unlock()
        body()
    }
}
