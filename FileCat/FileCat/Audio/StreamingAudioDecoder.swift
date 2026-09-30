import AudioToolbox
import AVFoundation

/// Decodes a song from a `RemoteStream` into PCM buffers for the audio engine, so music on a
/// server plays without downloading it first. Audio Toolbox reads the file through callbacks,
/// which block until the bytes are there. Use it from one serial queue only; every call can block.
final class StreamingAudioDecoder: @unchecked Sendable {
    let stream: RemoteStream
    private(set) var processingFormat: AVAudioFormat
    /// Length in frames (an estimate for some MP3s).
    private(set) var length: AVAudioFramePosition

    private var audioFile: AudioFileID?
    private var extAudioFile: ExtAudioFileRef?
    /// Set when a read failed, so decoding can report it instead of just ending.
    private(set) var readError: Error?
    private let cancelLock = NSLock()
    private var cancelled = false

    /// Stops reading from the server; the player calls this when it moves on to another song.
    func cancel() {
        cancelLock.withLock { cancelled = true }
    }

    private var isCancelled: Bool {
        cancelLock.withLock { cancelled }
    }

    /// Opens the stream; reads the file's header, so call it off the main thread.
    init(stream: RemoteStream) throws {
        self.stream = stream
        var fileID: AudioFileID?
        // Placeholder values until self is fully initialized; the callbacks need a pointer to it.
        processingFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        length = 0

        let status = AudioFileOpenWithCallbacks(
            Unmanaged.passUnretained(self).toOpaque(),
            { clientData, position, requestCount, buffer, actualCount in
                let decoder = Unmanaged<StreamingAudioDecoder>.fromOpaque(clientData).takeUnretainedValue()
                return decoder.read(position: position, count: requestCount, into: buffer, actualCount: actualCount)
            },
            nil,
            { clientData in
                Unmanaged<StreamingAudioDecoder>.fromOpaque(clientData).takeUnretainedValue().stream.size
            },
            nil,
            Self.typeHint(for: stream.name),
            &fileID
        )
        guard status == noErr, let fileID else { throw Self.error(status) }
        audioFile = fileID

        var extFile: ExtAudioFileRef?
        var result = ExtAudioFileWrapAudioFileID(fileID, false, &extFile)
        guard result == noErr, let extFile else { throw Self.error(result) }
        extAudioFile = extFile

        var fileFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        result = ExtAudioFileGetProperty(extFile, kExtAudioFileProperty_FileDataFormat, &size, &fileFormat)
        guard result == noErr, fileFormat.mSampleRate > 0, fileFormat.mChannelsPerFrame > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: fileFormat.mSampleRate, channels: fileFormat.mChannelsPerFrame)
        else { throw Self.error(result) }

        // Decode to the engine's usual format: 32-bit float, one buffer per channel.
        var clientFormat = format.streamDescription.pointee
        result = ExtAudioFileSetProperty(extFile, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientFormat)
        guard result == noErr else { throw Self.error(result) }

        var frames: Int64 = 0
        size = UInt32(MemoryLayout<Int64>.size)
        ExtAudioFileGetProperty(extFile, kExtAudioFileProperty_FileLengthFrames, &size, &frames)

        processingFormat = format
        length = max(0, frames)
    }

    deinit {
        if let extAudioFile { ExtAudioFileDispose(extAudioFile) }
        if let audioFile { AudioFileClose(audioFile) }
    }

    func seek(to frame: AVAudioFramePosition) {
        guard let extAudioFile else { return }
        ExtAudioFileSeek(extAudioFile, frame)
    }

    /// Fills `buffer` with the next frames; `frameLength` is 0 at the end of the song.
    func read(into buffer: AVAudioPCMBuffer) throws {
        guard let extAudioFile, !isCancelled else {
            buffer.frameLength = 0
            return
        }
        buffer.frameLength = buffer.frameCapacity
        var frames = buffer.frameCapacity
        let status = ExtAudioFileRead(extAudioFile, &frames, buffer.mutableAudioBufferList)
        if let readError { throw readError }
        guard status == noErr else { throw Self.error(status) }
        buffer.frameLength = frames
    }

    // MARK: Callbacks

    private func read(position: Int64, count: UInt32, into buffer: UnsafeMutableRawPointer, actualCount: UnsafeMutablePointer<UInt32>) -> OSStatus {
        guard !isCancelled else {
            actualCount.pointee = 0
            return kAudioFileUnspecifiedError
        }
        do {
            let data = try stream.readBlocking(offset: position, length: Int(count))
            data.withUnsafeBytes { bytes in
                if let base = bytes.baseAddress {
                    buffer.copyMemory(from: base, byteCount: data.count)
                }
            }
            actualCount.pointee = UInt32(data.count)
            return noErr
        } catch {
            readError = error
            actualCount.pointee = 0
            return kAudioFileUnspecifiedError
        }
    }

    private static func typeHint(for name: String) -> AudioFileTypeID {
        switch (name as NSString).pathExtension.lowercased() {
        case "mp3": kAudioFileMP3Type
        case "m4a", "m4b", "m4p", "alac": kAudioFileM4AType
        case "mp4": kAudioFileMPEG4Type
        case "aac", "adts": kAudioFileAAC_ADTSType
        case "wav", "wave": kAudioFileWAVEType
        case "aif", "aiff": kAudioFileAIFFType
        case "aifc": kAudioFileAIFCType
        case "caf": kAudioFileCAFType
        case "flac": kAudioFileFLACType
        case "ac3": kAudioFileAC3Type
        default: 0
        }
    }

    private static func error(_ status: OSStatus) -> Error {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "This song can't be streamed."])
    }
}
