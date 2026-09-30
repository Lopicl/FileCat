import AVFoundation
import Foundation

/// Tells when USB drives and SD cards are plugged in or out, with their names.
///
/// iOS has no general "volume mounted" notification for apps, but AVFoundation lists external
/// storage devices for cameras that record to them, and that list follows plugging and unplugging
/// (iPhone 15 Pro and later, and iPads with USB-C). It gives the drive's name only: iOS lets an
/// app into a drive once the user picks it in the Files picker.
@MainActor
final class ExternalDriveMonitor {
    /// Names of the drives plugged in right now.
    private(set) var driveNames: [String] = []
    /// False on devices without external storage support; then nothing is reported.
    let isSupported: Bool

    private var observation: NSKeyValueObservation?
    private let onChange: @MainActor () -> Void

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        #if DEBUG
        // For UI tests: `-FileCatUITestDrive "USB STICK"` pretends a new drive is plugged in.
        if let name = UserDefaults.standard.string(forKey: "FileCatUITestDrive") {
            isSupported = true
            driveNames = [name]
            return
        }
        #endif
        guard AVExternalStorageDeviceDiscoverySession.isSupported,
              let session = AVExternalStorageDeviceDiscoverySession.shared
        else {
            isSupported = false
            return
        }
        isSupported = true
        driveNames = Self.names(in: session)
        observation = session.observe(\.externalStorageDevices, options: [.new]) { [weak self] session, _ in
            let names = Self.names(in: session)
            Task { @MainActor in
                guard let self, names != self.driveNames else { return }
                self.driveNames = names
                self.onChange()
            }
        }
    }

    private nonisolated static func names(in session: AVExternalStorageDeviceDiscoverySession) -> [String] {
        session.externalStorageDevices
            .filter(\.isConnected)
            .compactMap(\.displayName)
            .filter { !$0.isEmpty }
    }
}
