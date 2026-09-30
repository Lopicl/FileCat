import AVFoundation
import UniformTypeIdentifiers

/// A download in progress, as seen by streaming playback: how much of the file has been written
/// so far. Downloads that write the file front to back (SMB, NFS) can be played from while they run.
final class ActiveDownload: @unchecked Sendable {
    let temporaryURL: URL
    /// False when the protocol only produces the file at the end (WebDAV).
    let isProgressive: Bool

    private let lock = NSLock()
    private var written: Int64 = 0
    private var ended = false
    private var completedURL: URL?
    private var descriptor: Int32 = -1

    init(temporaryURL: URL, isProgressive: Bool) {
        self.temporaryURL = temporaryURL
        self.isProgressive = isProgressive
    }

    deinit {
        if descriptor >= 0 { close(descriptor) }
    }

    func didWrite(_ bytes: Int64) {
        lock.withLock { written = max(written, bytes) }
    }

    func finish(at url: URL?) {
        lock.withLock {
            ended = true
            completedURL = url
        }
    }

    /// True while the download is still running.
    var isRunning: Bool {
        lock.withLock { !ended }
    }

    /// Bytes from the start of the file that can be read now.
    var available: Int64 {
        lock.withLock {
            if completedURL != nil { return .max }
            return isProgressive ? written : 0
        }
    }

    /// Reads already-downloaded bytes. The file is kept open, so this works even after the finished
    /// download has been moved into the cache.
    func read(offset: Int64, length: Int) -> Data? {
        lock.lock()
        if descriptor < 0 {
            let path = (completedURL ?? temporaryURL).path(percentEncoded: false)
            descriptor = open(path, O_RDONLY)
            if descriptor < 0, let completedURL {
                descriptor = open(completedURL.path(percentEncoded: false), O_RDONLY)
            }
        }
        let fd = descriptor
        lock.unlock()
        guard fd >= 0, length > 0 else { return nil }
        var data = Data(count: length)
        let count = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, length, off_t(offset)) }
        guard count > 0 else { return nil }
        data.count = count
        return data
    }
}

/// Serves any part of a server file while it downloads: from the download when it's already
/// there, by waiting a moment when it's about to arrive, or straight from the server for parts
/// far ahead (after seeking).
final class RemoteStream: @unchecked Sendable {
    /// The file's path on the server, and its name (which tells players its type).
    let path: String
    let name: String
    let size: Int64
    private let fileSystem: any RemoteFileSystem
    private let download: ActiveDownload?

    /// Server reads are fetched in chunks this size and a few are kept, because players ask for
    /// many small pieces.
    private static let chunkSize: Int64 = 512 * 1024
    private static let cachedChunks = 12
    /// How far ahead of the download a read may be and still wait for it rather than going to the server.
    private static let waitWindow: Int64 = 3 * 1024 * 1024

    private let lock = NSLock()
    private var chunks: [Int64: Data] = [:]
    private var chunkOrder: [Int64] = []

    init(path: String, name: String, size: Int64, fileSystem: any RemoteFileSystem, download: ActiveDownload?) {
        self.path = path
        self.name = name
        self.size = size
        self.fileSystem = fileSystem
        self.download = download
    }

    var contentType: String {
        UTType(filenameExtension: (name as NSString).pathExtension)?.identifier ?? UTType.data.identifier
    }

    func read(offset: Int64, length: Int) async throws -> Data {
        guard offset < size, length > 0 else { return Data() }
        let end = min(size, offset + Int64(length))
        var result = Data()
        var position = offset
        while position < end {
            try Task.checkCancellation()
            let piece = try await readPiece(at: position, upTo: end)
            if piece.isEmpty { break }
            result.append(piece)
            position += Int64(piece.count)
        }
        return result
    }

    /// For callers on their own thread (Audio Toolbox's file callbacks).
    func readBlocking(offset: Int64, length: Int) throws -> Data {
        final class Box: @unchecked Sendable { var result: Result<Data, Error> = .success(Data()) }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            do { box.result = .success(try await self.read(offset: offset, length: length)) } catch { box.result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try box.result.get()
    }

    private func readPiece(at position: Int64, upTo end: Int64) async throws -> Data {
        var waited = 0
        while let download {
            let available = download.available
            if position < available {
                let length = Int(min(end, available) - position)
                if let data = download.read(offset: position, length: length), !data.isEmpty { return data }
                break
            }
            // Just past what has arrived: it's quicker to wait than to ask the server separately.
            guard download.isRunning, download.isProgressive, position - available < Self.waitWindow, waited < 300 else { break }
            try await Task.sleep(for: .milliseconds(40))
            waited += 1
        }
        let index = position / Self.chunkSize
        let chunk = try await chunk(index)
        let start = Int(position - index * Self.chunkSize)
        guard start < chunk.count else { return Data() }
        return chunk.subdata(in: start..<min(chunk.count, start + Int(end - position)))
    }

    private func chunk(_ index: Int64) async throws -> Data {
        if let cached = lock.withLock({ chunks[index] }) { return cached }
        let offset = index * Self.chunkSize
        let data = try await fileSystem.read(path, offset: offset, length: Int(min(Self.chunkSize, size - offset)))
        lock.withLock {
            chunks[index] = data
            chunkOrder.removeAll { $0 == index }
            chunkOrder.append(index)
            while chunkOrder.count > Self.cachedChunks {
                chunks[chunkOrder.removeFirst()] = nil
            }
        }
        return data
    }
}

/// An `AVURLAsset` that reads from a `RemoteStream`. Keep it around as long as the asset plays:
/// the asset only holds its loader weakly.
final class StreamingAsset {
    let asset: AVURLAsset
    let stream: RemoteStream
    private let loader: StreamingAssetLoader
    private let onRelease: () -> Void

    init(stream: RemoteStream, onRelease: @escaping () -> Void = {}) {
        self.stream = stream
        self.onRelease = onRelease
        loader = StreamingAssetLoader(stream: stream)
        var components = URLComponents()
        components.scheme = "filecat-stream"
        components.host = "stream"
        components.path = "/" + UUID().uuidString + "/" + stream.name
        asset = AVURLAsset(url: components.url ?? URL(string: "filecat-stream://stream/media")!)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
    }

    /// Call when playback moves on; stops the download if nobody needs it anymore.
    func release() {
        loader.cancelAll()
        onRelease()
    }
}

private final class StreamingAssetLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let stream: RemoteStream
    let queue = DispatchQueue(label: "FileCat.streaming-loader")
    /// Only touched on `queue`.
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    private static let responseSize = 256 * 1024

    init(stream: RemoteStream) {
        self.stream = stream
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = stream.contentType
            info.contentLength = stream.size
            info.isByteRangeAccessSupported = true
        }
        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return true
        }
        let start = dataRequest.currentOffset != 0 ? dataRequest.currentOffset : dataRequest.requestedOffset
        let end = dataRequest.requestsAllDataToEndOfResource
            ? stream.size
            : min(stream.size, dataRequest.requestedOffset + Int64(dataRequest.requestedLength))
        let key = ObjectIdentifier(loadingRequest)
        let stream = stream
        let queue = queue
        tasks[key] = Task.detached(priority: .userInitiated) { [weak self] in
            var offset = start
            do {
                while offset < end {
                    try Task.checkCancellation()
                    let data = try await stream.read(offset: offset, length: Int(min(Int64(Self.responseSize), end - offset)))
                    if data.isEmpty { break }
                    try Task.checkCancellation()
                    queue.async { dataRequest.respond(with: data) }
                    offset += Int64(data.count)
                }
                queue.async {
                    if !loadingRequest.isCancelled, !loadingRequest.isFinished { loadingRequest.finishLoading() }
                    self?.tasks[key] = nil
                }
            } catch {
                queue.async {
                    if !loadingRequest.isCancelled, !loadingRequest.isFinished { loadingRequest.finishLoading(with: error) }
                    self?.tasks[key] = nil
                }
            }
        }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        tasks.removeValue(forKey: ObjectIdentifier(loadingRequest))?.cancel()
    }

    func cancelAll() {
        queue.async {
            self.tasks.values.forEach { $0.cancel() }
            self.tasks.removeAll()
        }
    }
}
