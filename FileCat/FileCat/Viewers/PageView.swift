import SwiftUI
import UIKit

/// A horizontally paging container backed by `UIPageViewController`.
///
/// SwiftUI's page-style `TabView` updates its selection while a swipe is still animating, and any
/// view update that follows can interrupt the paging animation and leave it resting between two
/// pages. `UIPageViewController` only reports a new page once the transition has finished, and
/// SwiftUI updates never touch its scroll position.
///
/// Each page's content is built once, when the page is created. Pages that need to react to
/// changing state should observe it themselves: pushing new root views into live hosting
/// controllers on every update makes them re-measure, which triggers another update, forever.
struct PageView<Content: View>: UIViewControllerRepresentable {
    let ids: [URL]
    @Binding var current: URL?
    var spacing: CGFloat = 20
    @ViewBuilder let content: (URL) -> Content

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal,
            options: [.interPageSpacing: spacing]
        )
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        controller.view.backgroundColor = .clear
        return controller
    }

    func updateUIViewController(_ controller: UIPageViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.dropRemovedPages()

        guard let current, ids.contains(current) else { return }
        let shown = (controller.viewControllers?.first as? PageHost)?.id
        if shown != current {
            controller.setViewControllers([coordinator.page(for: current)], direction: .forward, animated: false)
            coordinator.prune(around: current)
        }
    }

    final class PageHost: UIHostingController<AnyView> {
        let id: URL

        init(id: URL, rootView: AnyView) {
            self.id = id
            super.init(rootView: rootView)
            view.backgroundColor = .clear
            // Pages lay themselves out edge to edge; the gallery draws its own chrome on top.
            safeAreaRegions = []
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PageView
        /// Pages near the current one, reused while swiping back and forth.
        private var pages: [URL: PageHost] = [:]

        init(_ parent: PageView) {
            self.parent = parent
        }

        func page(for id: URL) -> PageHost {
            if let page = pages[id] {
                return page
            }
            let page = PageHost(id: id, rootView: AnyView(parent.content(id)))
            pages[id] = page
            return page
        }

        /// Forgets pages whose items are gone (e.g. deleted files).
        func dropRemovedPages() {
            let ids = Set(parent.ids)
            pages = pages.filter { ids.contains($0.key) }
        }

        /// Keeps only the current page and its neighbours, so big photos don't pile up in memory.
        func prune(around id: URL) {
            guard let index = parent.ids.firstIndex(of: id) else { return }
            let keep = Set(parent.ids[max(0, index - 1)...min(parent.ids.count - 1, index + 1)])
            pages = pages.filter { keep.contains($0.key) }
        }

        func pageViewController(_ controller: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
            neighbour(of: viewController, offset: -1)
        }

        func pageViewController(_ controller: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
            neighbour(of: viewController, offset: 1)
        }

        func pageViewController(_ controller: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            guard completed, let id = (controller.viewControllers?.first as? PageHost)?.id else { return }
            prune(around: id)
            if parent.current != id {
                parent.current = id
            }
        }

        private func neighbour(of viewController: UIViewController, offset: Int) -> UIViewController? {
            guard let id = (viewController as? PageHost)?.id,
                  let index = parent.ids.firstIndex(of: id),
                  parent.ids.indices.contains(index + offset)
            else { return nil }
            return page(for: parent.ids[index + offset])
        }
    }
}
