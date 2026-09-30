import AVFoundation
import Observation

struct EqualizerPreset: Identifiable, Hashable {
    let name: String
    /// Gain in dB for each of `Equalizer.frequencies`.
    let gains: [Float]

    var id: String { name }

    static let flat = EqualizerPreset(name: "Flat", gains: Array(repeating: 0, count: Equalizer.frequencies.count))

    static let all: [EqualizerPreset] = [
        flat,
        EqualizerPreset(name: "Acoustic", gains: [4, 4, 3, 1, 2, 2, 3, 3, 3, 2]),
        EqualizerPreset(name: "Bass Booster", gains: [6, 5, 4, 2.5, 1, 0, 0, 0, 0, 0]),
        EqualizerPreset(name: "Bass Reducer", gains: [-6, -5, -4, -2.5, -1, 0, 0, 0, 0, 0]),
        EqualizerPreset(name: "Classical", gains: [4, 3, 2, 1, -1, -1, 0, 2, 3, 4]),
        EqualizerPreset(name: "Electronic", gains: [5, 4, 1, 0, -2, 2, 1, 1, 4, 5]),
        EqualizerPreset(name: "Hip-Hop", gains: [5, 4, 1, 3, -1, -1, 1, -1, 2, 3]),
        EqualizerPreset(name: "Jazz", gains: [4, 3, 1, 2, -1, -1, 0, 1, 3, 4]),
        EqualizerPreset(name: "Loudness", gains: [6, 4, 0, 0, -2, 0, -1, -5, 5, 1]),
        EqualizerPreset(name: "Pop", gains: [-1, 0, 2, 4, 5, 4, 2, 0, -1, -1]),
        EqualizerPreset(name: "Rock", gains: [5, 4, 3, 1, -1, -1, 1, 3, 4, 5]),
        EqualizerPreset(name: "Treble Booster", gains: [0, 0, 0, 0, 0, 1, 2.5, 4, 5, 6]),
        EqualizerPreset(name: "Treble Reducer", gains: [0, 0, 0, 0, 0, -1, -2.5, -4, -5, -6]),
        EqualizerPreset(name: "Vocal Booster", gains: [-2, -2, -1, 0, 2, 4, 4, 3, 1, 0]),
    ]
}

/// A 10-band graphic equalizer applied to music playback. Settings are remembered across launches.
@MainActor
@Observable
final class Equalizer {
    nonisolated static let frequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    nonisolated static let gainRange: ClosedRange<Float> = -12...12

    /// The audio unit inserted between the player and the output.
    @ObservationIgnored let unit: AVAudioUnitEQ

    var isEnabled: Bool {
        didSet {
            apply()
            UserDefaults.standard.set(isEnabled, forKey: Keys.enabled)
        }
    }

    private(set) var gains: [Float] {
        didSet {
            apply()
            UserDefaults.standard.set(gains.map(Double.init), forKey: Keys.gains)
        }
    }

    /// The preset matching the current gains, or `nil` for a custom curve.
    var preset: EqualizerPreset? {
        EqualizerPreset.all.first { $0.gains == gains }
    }

    private enum Keys {
        static let enabled = "eqEnabled"
        static let gains = "eqGains"
    }

    init() {
        let defaults = UserDefaults.standard
        let savedGains = (defaults.array(forKey: Keys.gains) as? [Double])?.map(Float.init)
        gains = savedGains?.count == Self.frequencies.count ? savedGains! : EqualizerPreset.flat.gains
        isEnabled = defaults.bool(forKey: Keys.enabled)

        unit = AVAudioUnitEQ(numberOfBands: Self.frequencies.count)
        for (index, band) in unit.bands.enumerated() {
            band.frequency = Self.frequencies[index]
            // Shelves at the edges catch everything below/above the outer bands.
            band.filterType = index == 0 ? .lowShelf : index == Self.frequencies.count - 1 ? .highShelf : .parametric
            band.bandwidth = 1.0
            band.bypass = false
        }
        apply()
    }

    func setGain(_ gain: Float, forBand band: Int) {
        guard gains.indices.contains(band) else { return }
        gains[band] = min(max(gain, Self.gainRange.lowerBound), Self.gainRange.upperBound)
    }

    /// Back to a flat, switched-off equalizer (Settings → Reset All Settings).
    func reset() {
        isEnabled = false
        gains = EqualizerPreset.flat.gains
        UserDefaults.standard.removeObject(forKey: Keys.enabled)
        UserDefaults.standard.removeObject(forKey: Keys.gains)
    }

    func apply(_ preset: EqualizerPreset) {
        gains = preset.gains
    }

    nonisolated static func label(forBand band: Int) -> String {
        let frequency = frequencies[band]
        return frequency >= 1000 ? "\(Int(frequency / 1000))K" : "\(Int(frequency))"
    }

    private func apply() {
        for (band, gain) in zip(unit.bands, gains) {
            band.gain = gain
        }
        // Lower the overall level by the largest boost so boosted bands can't clip.
        unit.globalGain = -max(0, gains.max() ?? 0)
        unit.bypass = !isEnabled
    }
}
