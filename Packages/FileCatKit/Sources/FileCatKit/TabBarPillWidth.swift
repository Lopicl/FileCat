#if os(iOS)
import SwiftUI
import UIKit

extension View {
    /// Gives this view the width and position of the tab bar's pill below it (FileCat's and
    /// MusiCat's mini players), so the two line up in portrait and in landscape, where the pill
    /// shrinks to fit its tabs. Without a bottom tab bar (iPad, a hidden bar) it's inset by
    /// `fallbackInset`, at most `fallbackMaxWidth` wide.
    ///
    /// SwiftUI doesn't expose the pill, so the width is read from UIKit: the tab bar's widest
    /// subview is the pill (on iOS 26; before that it's the whole bar).
    public func matchingTabBarPill(fallbackInset: CGFloat = 21, fallbackMaxWidth: CGFloat = 500) -> some View {
        modifier(TabBarPillWidth(fallbackInset: fallbackInset, fallbackMaxWidth: fallbackMaxWidth))
    }
}

private struct TabBarPillWidth: ViewModifier {
    let fallbackInset: CGFloat
    let fallbackMaxWidth: CGFloat

    @State private var pill: TabBarPillProbe.Pill?

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: pill?.width ?? fallbackMaxWidth)
            .padding(.horizontal, pill == nil ? fallbackInset : 0)
            .offset(x: pill?.centerOffset ?? 0)
            .frame(maxWidth: .infinity)
            .background(TabBarPillProbe(pill: $pill))
    }
}

private struct TabBarPillProbe: UIViewRepresentable {
    struct Pill: Equatable {
        var width: CGFloat
        /// How far the pill's center is from the center of the probed view.
        var centerOffset: CGFloat
    }

    @Binding var pill: Pill?

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        view.onChange = { pill in
            if self.pill != pill { self.pill = pill }
        }
    }

    final class ProbeView: UIView {
        var onChange: ((Pill?) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            measureSoon()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // The tab bar may lay out after this view (rotating), so look again once it has.
            measureSoon()
        }

        private func measureSoon() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                onChange?(measure())
            }
        }

        private func measure() -> Pill? {
            guard let window, bounds.width > 0,
                  let controller = sequence(first: next, next: { $0?.next }).first(where: { $0 is UITabBarController }) as? UITabBarController
            else { return nil }
            let bar = controller.tabBar
            guard !bar.isHidden, bar.alpha > 0.01, bar.window === window,
                  // On iPad the tabs sit at the top, with nothing to line up with.
                  bar.convert(bar.bounds, to: window).minY > window.bounds.midY,
                  let platter = bar.subviews
                      .filter({ !$0.isHidden && $0.alpha > 0.01 && $0.bounds.height > 30 })
                      .max(by: { $0.bounds.width < $1.bounds.width })
            else { return nil }
            let frame = platter.convert(platter.bounds, to: self)
            // Before iOS 26 the bar is edge to edge; keep the inset there.
            guard frame.width < bounds.width - 1 else { return nil }
            return Pill(width: frame.width.rounded(), centerOffset: (frame.midX - bounds.midX).rounded())
        }
    }
}
#endif
