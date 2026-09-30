#if os(iOS)
import AVFoundation
import SwiftUI

/// The cat at the very end of Settings (in FileCat and MusiCat), seen from above: a head with ears, eyes, a nose and
/// whiskers on a body that goes on past the bottom of the screen, however far you pull. Pull hard
/// enough and it meows. Traced from a 680×680 SVG, whose coordinates the drawing keeps.
public struct LongCat: View {
    /// Times it has meowed; also its accessibility value, for UI tests.
    var meows = 0

    public init(meows: Int = 0) {
        self.meows = meows
    }

    /// Points per unit of the SVG's 680-unit view box.
    private let scale: CGFloat = 0.8

    public var body: some View {
        CatFace()
            .frame(width: CatFace.box.width * scale, height: CatFace.box.height * scale)
            // The body, drawn much longer than the space it takes, so the end is never in sight
            // (not even while the list rubber-bands past its bottom). It starts under the face so
            // the two overlap without a seam.
            .background(alignment: .top) {
                Rectangle()
                    .frame(width: CatFace.bodyWidth * scale, height: 4000)
                    .offset(y: (CatFace.bodyJoin - CatFace.box.minY) * scale)
            }
            .foregroundStyle(Self.gray)
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
            .accessibilityElement()
            .accessibilityLabel("A very long cat")
            .accessibilityValue("\(meows)")
            .accessibilityIdentifier("longCat")
    }

    /// Dark gray in light mode, light gray in dark mode.
    private static let gray = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? .lightGray : .darkGray
    })
}

/// The top of the cat, in the SVG's coordinates: ears, the rounded top of the body, whiskers, and
/// the eyes and nose cut out of it. The layout frame ends a little below the whiskers.
private struct CatFace: View {
    /// The part of the view box drawn here.
    static let box = CGRect(x: 266, y: 26, width: 148, height: 100)
    static let bodyWidth: CGFloat = 80
    /// Where the separately drawn rest of the body begins.
    static let bodyJoin: CGFloat = 116

    var body: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / Self.box.width, y: size.height / Self.box.height)
            context.translateBy(x: -Self.box.minX, y: -Self.box.minY)

            context.fill(Path(roundedRect: CGRect(x: 300, y: 52, width: 80, height: 200), cornerRadius: 40), with: .foreground)
            for ear: [(CGFloat, CGFloat)] in [[(306, 72), (296, 28), (334, 55)], [(374, 72), (384, 28), (346, 55)]] {
                context.fill(Self.polygon(ear), with: .foreground)
            }
            var whiskers = Path()
            for (from, to) in [((300, 100), (268, 92)), ((300, 108), (268, 112)),
                               ((380, 100), (412, 92)), ((380, 108), (412, 112))] {
                whiskers.move(to: CGPoint(x: from.0, y: from.1))
                whiskers.addLine(to: CGPoint(x: to.0, y: to.1))
            }
            context.stroke(whiskers, with: .foreground, style: StrokeStyle(lineWidth: 2, lineCap: .round))

            // Eyes and nose, cut out of the head.
            context.blendMode = .destinationOut
            for x in [325.0, 355.0] {
                context.fill(Path(ellipseIn: CGRect(x: x - 7, y: 79, width: 14, height: 18)), with: .color(.black))
            }
            context.fill(Self.polygon([(335, 102), (345, 102), (340, 108)]), with: .color(.black))
        }
        .compositingGroup()
    }

    private static func polygon(_ points: [(CGFloat, CGFloat)]) -> Path {
        Path { path in
            path.addLines(points.map { CGPoint(x: $0.0, y: $0.1) })
            path.closeSubpath()
        }
    }
}

public extension View {
    /// Calls `action` when the scroll view is dragged up past its end by more than `threshold`
    /// points, which rubber-banding makes hard: it takes a long, deliberate drag with the finger
    /// down. Flinging into the end doesn't count. Fires once per pull. Use it on a `Form`: a
    /// `List` doesn't report its scroll phase, so the pull never counts there.
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
public enum Meow {
    private static var player: AVAudioPlayer?
    private static let sound: Data = makeWAV()

    public static func play() {
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
#endif
