// Streaming tests: plays server files the way FileCat does while they download (RemoteStream,
// StreamingAsset, StreamingAudioDecoder). Run with `run.sh stream` after `servers.sh`.
// The video part needs a movie at $FILECAT_TEST_ROOT/Videos/clip.mp4 and is skipped without one.
import AVFoundation
import Foundation

let root = ProcessInfo.processInfo.environment["FILECAT_TEST_ROOT"] ?? "/tmp/filecat-test-server"
var failures = 0
func check(_ c: Bool, _ m: String) { print(c ? "  ok   \(m)" : "  FAIL \(m)"); if !c { failures += 1 } }

func run(_ fs: any RemoteFileSystem, label: String, progressive: Bool) async {
    print("== \(label)")
    // 1. Ranged reads while a download runs.
    let hasVideo = FileManager.default.fileExists(atPath: root + "/Videos/clip.mp4")
    let path = hasVideo ? "/Videos/clip.mp4" : "/big.bin"
    let size = Int64((try? FileManager.default.attributesOfItem(atPath: root + path)[.size] as? Int) ?? 0)
    let original = try! Data(contentsOf: URL(filePath: root + path))
    let temp = URL.temporaryDirectory.appending(path: "st-\(label)-\(UUID().uuidString).mp4")
    let active = ActiveDownload(temporaryURL: temp, isProgressive: progressive)
    let downloadTask = Task { try await fs.download(path, to: temp) { active.didWrite($0) }; active.finish(at: temp) }
    let stream = RemoteStream(path: path, name: RemotePath.name(of: path), size: size, fileSystem: fs, download: active)
    for (offset, length) in [(Int64(0), 1000), (size / 2, 700_000), (size - 5000, 10_000), (1_234_567, 3)] {
        do {
            let data = try await stream.read(offset: offset, length: length)
            let expected = original.subdata(in: Int(offset)..<Int(min(size, offset + Int64(length))))
            check(data == expected, "range \(offset)+\(length) (\(data.count) bytes)")
        } catch { check(false, "range \(offset) threw \(error)") }
    }
    // 2. AVFoundation through the resource loader.
    let asset = StreamingAsset(stream: stream)
    if !hasVideo { print("  skip video (no Videos/clip.mp4)") }
    else { do {
        let duration = try await asset.asset.load(.duration)
        let tracks = try await asset.asset.load(.tracks)
        check(duration.seconds > 1 && !tracks.isEmpty, "video asset loads: \(String(format: "%.1f", duration.seconds))s, \(tracks.count) tracks")
        let generator = AVAssetImageGenerator(asset: asset.asset)
        let (image, _) = try await generator.image(at: CMTime(seconds: duration.seconds / 2, preferredTimescale: 600))
        check(image.width > 0, "decodes a frame from the middle (\(image.width)x\(image.height))")
    } catch { check(false, "asset threw \(error)") } }
    asset.release()
    _ = try? await downloadTask.value
    // 3. Music through Audio Toolbox callbacks.
    for name in ["stream.m4a", "stream.flac", "stream.wav"] {
        let mpath = "/Music/" + name
        let msize = Int64((try! FileManager.default.attributesOfItem(atPath: root + mpath)[.size] as! Int))
        let mstream = RemoteStream(path: mpath, name: name, size: msize, fileSystem: fs, download: nil)
        do {
            let decoder = try StreamingAudioDecoder(stream: mstream)
            let reference = try AVAudioFile(forReading: URL(filePath: root + mpath))
            var total: AVAudioFramePosition = 0
            let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 16384)!
            repeat { try decoder.read(into: buffer); total += AVAudioFramePosition(buffer.frameLength) } while buffer.frameLength > 0
            decoder.seek(to: decoder.length / 2)
            try decoder.read(into: buffer)
            check(abs(total - reference.length) < 4096 && decoder.length > 0 && buffer.frameLength > 0,
                  "\(name): decoded \(total) frames, file has \(reference.length), length \(decoder.length), seek ok")
        } catch { check(false, "\(name) threw \(error)") }
    }
    await fs.close()
}

var smb = NetworkSource(kind: .smb, name: "smb", host: "127.0.0.1"); smb.port = 4451; smb.path = "Media"; smb.username = NSUserName()
var nfs = NetworkSource(kind: .nfs, name: "nfs", host: "127.0.0.1"); nfs.port = 12049; nfs.path = "/"
var dav = NetworkSource(kind: .webdav, name: "dav", host: "http://127.0.0.1:8081/"); dav.username = "test"
await run(try! await RemoteConnections.connect(smb, password: "secret"), label: "smb", progressive: true)
await run(try! await RemoteConnections.connect(nfs), label: "nfs", progressive: true)
await run(try! await RemoteConnections.connect(dav, password: "secret"), label: "webdav", progressive: false)
print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
