import AVFoundation
import SwiftUI

/// The cat at the very end of Settings. Its body goes on past the bottom of the screen, however
/// far you pull. Pull hard enough and it meows.
struct LongCat: View {
    /// Times it has meowed; also its accessibility value, for UI tests.
    var meows = 0

    private let headWidth: CGFloat = 132

    var body: some View {
        VStack(spacing: 0) {
            CatHead()
                .frame(width: headWidth, height: 118)
            // The body, drawn much longer than the space it takes, so the end is never in sight
            // (not even while the list rubber-bands past its bottom).
            Rectangle()
                .frame(width: 58, height: 120)
                .overlay(alignment: .top) {
                    CatLegs()
                        .frame(width: 94, height: 70)
                        .offset(y: -6)
                }
                .overlay(alignment: .top) {
                    Rectangle()
                        .frame(width: 58, height: 4000)
                        .offset(y: 118)
                }
        }
        .foregroundStyle(Color.primary)
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .accessibilityElement()
        .accessibilityLabel("A very long cat")
        .accessibilityValue("\(meows)")
        .accessibilityIdentifier("longCat")
    }
}

/// A wide, soft head with pointed ears and two narrow eyes, in the style of the app icon's cat.
private struct CatHead: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            context.fill(Path(ellipseIn: CGRect(x: 0, y: h * 0.28, width: w, height: h * 0.72)), with: .foreground)
            for side: CGFloat in [-1, 1] {
                let cx = w / 2
                var ear = Path()
                ear.move(to: CGPoint(x: cx + side * w * 0.40, y: h * 0.50))
                ear.addLine(to: CGPoint(x: cx + side * w * 0.43, y: h * 0.05))
                ear.addLine(to: CGPoint(x: cx + side * w * 0.10, y: h * 0.34))
                ear.closeSubpath()
                // Fill plus a round-joined stroke softens the tips, like the app icon's ears.
                context.fill(ear, with: .foreground)
                context.stroke(ear, with: .foreground, style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
            }

            // Eyes: calm slits, cut out of the head.
            context.blendMode = .destinationOut
            for side: CGFloat in [-1, 1] {
                let eye = CGRect(x: w / 2 + side * w * 0.2 - w * 0.07, y: h * 0.58, width: w * 0.14, height: h * 0.07)
                context.fill(Path(ellipseIn: eye), with: .color(.black))
            }
        }
        .compositingGroup()
    }
}

/// Front legs hanging down on either side of the body, like a cat being held up.
private struct CatLegs: View {
    var body: some View {
        HStack {
            Capsule().frame(width: 20, height: 70)
            Spacer()
            Capsule().frame(width: 20, height: 70)
        }
    }
}

extension View {
    /// Calls `action` when the scroll view is dragged up past its end by more than `threshold`
    /// points, which rubber-banding makes hard: it takes a long, deliberate drag with the finger
    /// down. Flinging into the end doesn't count. Fires once per pull.
    func onHardOverscroll(threshold: CGFloat = 150, perform action: @escaping () -> Void) -> some View {
        modifier(HardOverscroll(threshold: threshold, action: action))
    }
}

private struct HardOverscroll: ViewModifier {
    let threshold: CGFloat
    let action: () -> Void

    @State private var isArmed = true
    @State private var isDragging = false

    func body(content: Content) -> some View {
        content
            .onScrollPhaseChange { _, phase in
                isDragging = phase == .interacting
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
            // How far the bottom of the content has been dragged above the bottom of the view.
            geometry.contentOffset.y + geometry.containerSize.height
                - geometry.contentSize.height - geometry.contentInsets.bottom
        } action: { _, overscroll in
            if overscroll > threshold, isArmed, isDragging {
                isArmed = false
                action()
            } else if overscroll < 20 {
                isArmed = true
            }
        }
    }
}

/// A meow, synthesized: a rising then falling pitch with a vowel that opens from "ee" to "ah" and
/// closes to "oo", like "mee-ah-ow".
@MainActor
enum Meow {
    private static var player: AVAudioPlayer?
    private static let sound: Data = makeWAV()

    static func play() {
        player = try? AVAudioPlayer(data: sound)
        player?.volume = 0.8
        player?.play()
    }

    private static func makeWAV() -> Data {
        let sampleRate = 44_100.0
        let duration = 0.62
        let count = Int(sampleRate * duration)
        var samples = [Float](repeating: 0, count: count)
        var phase = 0.0

        func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
        /// Piecewise curve through (0, a), (0.35, b), (1, c).
        func contour(_ a: Double, _ b: Double, _ c: Double, _ t: Double) -> Double {
            t < 0.35 ? lerp(a, b, t / 0.35) : lerp(b, c, (t - 0.35) / 0.65)
        }

        for i in 0..<count {
            let t = Double(i) / Double(count)
            let time = Double(i) / sampleRate
            // Pitch: up, then a long slide down, with a little vibrato.
            let pitch = contour(560, 880, 470, t) * (1 + 0.012 * sin(2 * .pi * 6 * time))
            phase += 2 * .pi * pitch / sampleRate
            // Formants for the vowel.
            let f1 = contour(420, 850, 460, t)
            let f2 = contour(2100, 1300, 850, t)
            var value = 0.0
            for harmonic in 1...14 {
                let frequency = pitch * Double(harmonic)
                let emphasis = exp(-pow((frequency - f1) / 260, 2)) + 0.7 * exp(-pow((frequency - f2) / 420, 2))
                value += (0.15 / Double(harmonic) + emphasis) * sin(phase * Double(harmonic))
            }
            // Envelope: quick attack, gentle fade.
            let attack = min(1, time / 0.04)
            let release = min(1, (duration - time) / 0.18)
            samples[i] = Float(value * attack * max(0, release) * 0.22)
        }

        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + count * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(count * 2))
        for sample in samples {
            append(Int16(max(-1, min(1, sample)) * 32_000))
        }
        return data
    }
}
