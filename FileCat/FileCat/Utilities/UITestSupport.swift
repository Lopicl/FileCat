#if DEBUG
import AVFoundation
import UIKit

/// When launched with `-FileCatUITestReset YES`, wipes the app's storage and fills it with a small,
/// known set of files so UI tests are repeatable.
enum UITestSupport {
    static func prepareIfNeeded() {
        guard UserDefaults.standard.bool(forKey: "FileCatUITestReset") else { return }
        let root = FileService.documentsDirectory
        let fileManager = FileManager.default

        for url in (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            try? fileManager.removeItem(at: url)
        }
        for key in ["savedLocations", "fileTags", SourceStore.defaultsKey, "offlinePins"] + AppSettings.resettable {
            UserDefaults.standard.removeObject(forKey: key)
        }
        for folder in [RemoteCache.cacheRoot, RemoteCache.offlineRoot] {
            try? fileManager.removeItem(at: folder)
        }

        let docs = root.appending(path: "Docs")
        try? fileManager.createDirectory(at: docs, withIntermediateDirectories: true)
        try? "# Project Notes\n\n- [x] Done item\n- [ ] Open item\n".write(to: root.appending(path: "notes.md"), atomically: true, encoding: .utf8)
        try? "Hello from a plain text file.".write(to: root.appending(path: "hello.txt"), atomically: true, encoding: .utf8)
        try? "Nested file".write(to: docs.appending(path: "nested.txt"), atomically: true, encoding: .utf8)
        // What iCloud leaves in a folder for a file that isn't downloaded.
        let placeholder = try? PropertyListSerialization.data(
            fromPropertyList: ["NSURLNameKey": "Cloud Report.pdf", "NSURLFileSizeKey": 12_345, "NSURLFileResourceTypeKey": "NSURLFileResourceTypeRegular"],
            format: .binary, options: 0
        )
        try? placeholder?.write(to: docs.appending(path: ".Cloud Report.pdf.icloud"))

        let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300)).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }
        try? image.jpegData(compressionQuality: 0.8)?.write(to: root.appending(path: "photo.jpg"))

        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { context in
            for page in 1...2 {
                context.beginPage()
                ("Page \(page)" as NSString).draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 32)])
            }
        }
        try? pdf.write(to: root.appending(path: "report.pdf"))

        try? toneWAV(seconds: 60).write(to: root.appending(path: "tone.wav"))
        writeTestVideo(to: root.appending(path: "clip.mp4"), seconds: 4)
    }

    /// For testing folders from Files: launch with `-FileCatUITestLocation Tunes` to add a folder
    /// named Tunes, holding "Drive Song.wav", as if it was picked in the Files picker.
    @MainActor
    static func addTestLocationIfNeeded(to store: LocationStore) {
        guard let name = UserDefaults.standard.string(forKey: "FileCatUITestLocation") else { return }
        let folder = URL.temporaryDirectory.appending(path: "UITestLocations").appending(path: name)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? toneWAV(seconds: 5).write(to: folder.appending(path: "Drive Song.wav"))
        _ = try? store.add(folder)
    }

    /// For testing the activity indicator and Live Activity: launch with
    /// `-FileCatDemoActivity <seconds>` to run a fake copy that takes that long.
    @MainActor
    static func startDemoActivityIfNeeded() {
        let seconds = UserDefaults.standard.integer(forKey: "FileCatDemoActivity")
        guard seconds > 0 else { return }
        Task {
            _ = try? await ActivityCenter.shared.run(.copy, name: "Holiday Photos", total: Int64(seconds * 10)) { cancellation, progress in
                for step in 1...(seconds * 10) {
                    if cancellation.isCancelled { throw CancellationError() }
                    Thread.sleep(forTimeInterval: 0.1)
                    progress(Int64(step))
                }
            }
        }
    }

    /// A small H.264 clip that fades through the rainbow.
    private static func writeTestVideo(to url: URL, seconds: Int) {
        let (width, height, fps) = (320, 240, 10)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let frames = seconds * fps
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { usleep(1000) }
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool,
                  CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
                  let buffer
            else { break }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
            ) {
                let hue = CGFloat(frame) / CGFloat(frames)
                context.setFillColor(UIColor(hue: hue, saturation: 0.7, brightness: 0.9, alpha: 1).cgColor)
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
    }

    /// A quiet 440 Hz sine wave as 16-bit mono PCM.
    private static func toneWAV(seconds: Int) -> Data {
        let sampleRate = 22_050
        let count = sampleRate * seconds
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + count * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(count * 2))
        for i in 0..<count {
            append(Int16(sin(Double(i) * 2 * .pi * 440 / Double(sampleRate)) * 3000))
        }
        return data
    }
}
#endif
