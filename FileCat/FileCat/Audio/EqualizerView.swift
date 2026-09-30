import SwiftUI

/// The equalizer as a sheet, opened from the music player.
struct EqualizerView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            EqualizerSettings()
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDetents([.large])
    }
}

/// The equalizer's controls: on/off, presets and the ten bands. Shown in the music player's sheet
/// and in Settings.
struct EqualizerSettings: View {
    @Environment(AudioPlayer.self) private var player

    private var equalizer: Equalizer { player.equalizer }

    var body: some View {
        @Bindable var equalizer = equalizer

        List {
            Section {
                Toggle("Equalizer", isOn: $equalizer.isEnabled)
                Picker("Preset", selection: presetSelection) {
                    ForEach(EqualizerPreset.all) { preset in
                        Text(preset.name).tag(Optional(preset))
                    }
                    if equalizer.preset == nil {
                        Text("Custom").tag(EqualizerPreset?.none)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!equalizer.isEnabled)
            }

            Section {
                bands
                    .disabled(!equalizer.isEnabled)
                    .opacity(equalizer.isEnabled ? 1 : 0.4)
                    .animation(.easeInOut(duration: 0.2), value: equalizer.isEnabled)
            } footer: {
                Text("Drag a slider to boost or cut a frequency band. The overall volume is lowered automatically when you boost, to avoid distortion.")
            }
        }
        .navigationTitle("Equalizer")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Reset") {
                    withAnimation { equalizer.apply(.flat) }
                }
                .disabled(!equalizer.isEnabled || equalizer.preset == .flat)
            }
        }
    }

    /// "0", "+6", "-2.5"
    private static func gainLabel(_ gain: Float) -> String {
        if gain == 0 { return "0" }
        return String(format: gain.rounded() == gain ? "%+.0f" : "%+.1f", Double(gain))
    }

    private var presetSelection: Binding<EqualizerPreset?> {
        Binding {
            equalizer.preset
        } set: { preset in
            if let preset {
                withAnimation(.snappy) { equalizer.apply(preset) }
            }
        }
    }

    private var bands: some View {
        HStack(alignment: .top, spacing: 2) {
            // dB scale
            VStack {
                Text("+12")
                Spacer()
                Text("0")
                Spacer()
                Text("-12")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
            .frame(height: 220)
            .padding(.top, 22)

            ForEach(Equalizer.frequencies.indices, id: \.self) { band in
                let gain = equalizer.gains[band]
                VStack(spacing: 6) {
                    Text(Self.gainLabel(gain))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(gain == 0 ? .secondary : .primary)
                        .frame(height: 16)
                    VerticalSlider(
                        value: Binding(get: { gain }, set: { equalizer.setGain($0, forBand: band) }),
                        range: Equalizer.gainRange
                    )
                    .frame(height: 220)
                    .accessibilityLabel("\(Equalizer.label(forBand: band)) hertz")
                    Text(Equalizer.label(forBand: band))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 8)
    }
}

/// A vertical slider centred on zero, like the bands of a graphic equalizer.
struct VerticalSlider: View {
    @Binding var value: Float
    let range: ClosedRange<Float>
    var step: Float = 0.5

    @Environment(\.isEnabled) private var isEnabled
    private let thumbSize: CGFloat = 22

    var body: some View {
        GeometryReader { proxy in
            track(in: proxy.size)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in update(dragY: drag.location.y, height: proxy.size.height) }
                )
        }
        .accessibilityElement()
        .accessibilityValue(String(format: "%+.1f decibels", Double(value)))
        .accessibilityAdjustableAction(adjust)
        .sensoryFeedback(.selection, trigger: value, condition: crossesZero)
    }

    private func adjust(_ direction: AccessibilityAdjustmentDirection) {
        switch direction {
        case .increment: value = min(range.upperBound, value + 1)
        case .decrement: value = max(range.lowerBound, value - 1)
        @unknown default: break
        }
    }

    /// A haptic tick when crossing zero, so you can find flat by feel.
    private func crossesZero(_ old: Float, _ new: Float) -> Bool {
        (old < 0) != (new < 0) || new == 0
    }

    private func track(in size: CGSize) -> some View {
        let usable = max(1, size.height - thumbSize)
        let centerX = size.width / 2
        let valueY = yPosition(for: value, usable: usable)
        let zeroY = yPosition(for: min(max(0, range.lowerBound), range.upperBound), usable: usable)

        return ZStack {
            Capsule()
                .fill(Color(uiColor: .systemFill))
                .frame(width: 4, height: usable)
                .position(x: centerX, y: size.height / 2)
            Capsule()
                .fill(Color.accentColor)
                .frame(width: 4, height: abs(valueY - zeroY))
                .position(x: centerX, y: (valueY + zeroY) / 2)
            Circle()
                .fill(Color.white)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                .frame(width: thumbSize, height: thumbSize)
                .position(x: centerX, y: valueY)
        }
    }

    private func update(dragY: CGFloat, height: CGFloat) {
        guard isEnabled else { return }
        let usable = max(1, height - thumbSize)
        let fraction = 1 - Float((dragY - thumbSize / 2) / usable)
        let raw = range.lowerBound + fraction * (range.upperBound - range.lowerBound)
        let snapped = (raw / step).rounded() * step
        let clamped = min(max(snapped, range.lowerBound), range.upperBound)
        if clamped != value {
            value = clamped
        }
    }

    private func yPosition(for value: Float, usable: CGFloat) -> CGFloat {
        let fraction = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
        return thumbSize / 2 + (1 - fraction) * usable
    }
}
