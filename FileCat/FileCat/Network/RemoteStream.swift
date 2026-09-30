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

/// The parts of a server file that have been streamed so far, kept on the device so they're
/// fetched only once. The data sits at its place in a sparse file; a second file next to it
/// (`<name>.chunks`) has one byte per `RemoteStream.chunkSize` chunk, set once that chunk arrived.
final class PartialFile: @unchecked Sendable {
    let url: URL
    private let size: Int64
    private let dataDescriptor: Int32
    private let mapDescriptor: Int32
    /// Called once, from any thread, when every chunk has arrived.
    private let onComplete: @Sendable (URL) -> Void

    private let lock = NSLock()
    private var arrived: [UInt8]
    private var missing: Int

    init?(url: URL, size: Int64, onComplete: @escaping @Sendable (URL) -> Void) {
        let count = Int((size + RemoteStream.chunkSize - 1) / RemoteStream.chunkSize)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let path = url.path(percentEncoded: false)
        let dataDescriptor = open(path, O_RDWR | O_CREAT, 0o644)
        let mapDescriptor = open(path + ".chunks", O_RDWR | O_CREAT, 0o644)
        guard dataDescriptor >= 0, mapDescriptor >= 0, ftruncate(dataDescriptor, off_t(size)) == 0 else {
            if dataDescriptor >= 0 { close(dataDescriptor) }
            if mapDescriptor >= 0 { close(mapDescriptor) }
            return nil
        }
        var arrived = [UInt8](repeating: 0, count: count)
        let read = arrived.withUnsafeMutableBytes { pread(mapDescriptor, $0.baseAddress, count, 0) }
        if read != count {
            // New, or left by a different version of the file: start empty.
            arrived = [UInt8](repeating: 0, count: count)
            ftruncate(mapDescriptor, 0)
            ftruncate(mapDescriptor, off_t(count))
        }
        self.url = url
        self.size = size
        self.dataDescriptor = dataDescriptor
        self.mapDescriptor = mapDescriptor
        self.onComplete = onComplete
        self.arrived = arrived
        missing = arrived.count(where: { $0 == 0 })
    }

    deinit {
        close(dataDescriptor)
        close(mapDescriptor)
    }

    private func length(of index: Int64) -> Int {
        Int(min(RemoteStream.chunkSize, size - index * RemoteStream.chunkSize))
    }

    func contains(_ index: Int64) -> Bool {
        lock.withLock { index >= 0 && Int(index) < arrived.count && arrived[Int(index)] != 0 }
    }

    /// The chunk, if it has arrived.
    func read(_ index: Int64) -> Data? {
        guard contains(index) else { return nil }
        let length = length(of: index)
        var data = Data(count: length)
        let count = data.withUnsafeMutableBytes { pread(dataDescriptor, $0.baseAddress, length, off_t(index * RemoteStream.chunkSize)) }
        return count == length ? data : nil
    }

    func write(_ data: Data, at index: Int64) {
        guard index >= 0, Int(index) < arrived.count, data.count == length(of: index), !contains(index) else { return }
        let written = data.withUnsafeBytes { pwrite(dataDescriptor, $0.baseAddress, data.count, off_t(index * RemoteStream.chunkSize)) }
        guard written == data.count else { return }
        var flag: UInt8 = 1
        guard pwrite(mapDescriptor, &flag, 1, off_t(index)) == 1 else { return }
        let isComplete = lock.withLock {
            guard arrived[Int(index)] == 0 else { return false }
            arrived[Int(index)] = 1
            missing -= 1
            return missing == 0
        }
        if isComplete { onComplete(url) }
    }
}

/// Serves any part of a server file: from a download when one is running and has got there
/// (waiting a moment when it's about to arrive), otherwise straight from the server, a chunk at a
/// time. With a `PartialFile`, fetched chunks are kept on the device; without, a few stay in memory.
final class RemoteStream: @unchecked Sendable {
    /// The file's path on the server, and its name (which tells players its type).
    let path: String
    let name: String
    let size: Int64
    private let fileSystem: any RemoteFileSystem
    private let download: ActiveDownload?
    private let partial: PartialFile?
    /// How many chunks past the one just read to fetch in advance, so playback doesn't wait on
    /// a round trip for every chunk.
    private let readAhead: Int

    /// Server reads are fetched in chunks this size, because players ask for many small pieces.
    static let chunkSize: Int64 = 512 * 1024
    private static let cachedChunks = 12
    /// How far ahead of the download a read may be and still wait for it rather than going to the server.
    private static let waitWindow: Int64 = 3 * 1024 * 1024

    private let lock = NSLock()
    private var chunks: [Int64: Data] = [:]
    private var chunkOrder: [Int64] = []
    private var fetching: [Int64: Task<Data, Error>] = [:]

    init(
        path: String, name: String, size: Int64, fileSystem: any RemoteFileSystem, download: ActiveDownload?,
        partial: PartialFile? = nil, readAhead: Int = 0
    ) {
        self.path = path
        self.name = name
        self.size = size
        self.fileSystem = fileSystem
        self.download = download
        self.partial = partial
        self.readAhead = readAhead
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
        let stored = partial?.read(index) ?? lock.withLock { chunks[index] }
        let current = stored == nil ? fetch(index) : nil
        // A running download fetches ahead already.
        if download?.isRunning != true {
            let last = (size - 1) / Self.chunkSize
            for next in stride(from: index + 1, through: min(last, index + Int64(readAhead)), by: 1) where !has(next) {
                _ = fetch(next)
            }
        }
        if let current { return try await current.value }
        return stored ?? Data()
    }

    private func has(_ index: Int64) -> Bool {
        partial?.contains(index) ?? lock.withLock { chunks[index] != nil }
    }

    /// Fetches a chunk from the server, or joins the fetch that's already running. Fetches aren't
    /// cancelled with the read that started them: the chunk is worth keeping either way.
    private func fetch(_ index: Int64) -> Task<Data, Error> {
        lock.withLock {
            if let task = fetching[index] { return task }
            let task = Task {
                defer { lock.withLock { fetching[index] = nil } }
                let offset = index * Self.chunkSize
                let data = try await fileSystem.read(path, offset: offset, length: Int(min(Self.chunkSize, size - offset)))
                keep(data, at: index)
                return data
            }
            fetching[index] = task
            return task
        }
    }

    private func keep(_ data: Data, at index: Int64) {
        if let partial {
            partial.write(data, at: index)
            return
        }
        lock.withLock {
            chunks[index] = data
            chunkOrder.removeAll { $0 == index }
            chunkOrder.append(index)
            while chunkOrder.count > Self.cachedChunks {
                chunks[chunkOrder.removeFirst()] = nil
            }
        }
    }
}

/// An `AVURLAsset` that reads from a `RemoteStream`. Keep it around as long as the asset plays:
/// the asset only holds its loader weakly.
final class StreamingAsset {
    let asset: AVURLAsset
    let stream: RemoteStream
    private let loader: StreamingAssetLoader

    init(stream: RemoteStream) {
        self.stream = stream
        loader = StreamingAssetLoader(stream: stream)
        var components = URLComponents()
        components.scheme = "filecat-stream"
        components.host = "stream"
        components.path = "/" + UUID().uuidString + "/" + stream.name
        asset = AVURLAsset(url: components.url ?? URL(string: "filecat-stream://stream/media")!)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
    }

    /// Call when playback moves on, so reads the player still had waiting stop.
    func release() {
        loader.cancelAll()
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
