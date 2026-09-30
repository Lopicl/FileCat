import PDFKit
import SwiftUI

struct PDFViewer: View {
    let item: FileItem

    @State private var controller = PDFController()
    @State private var password = ""

    var body: some View {
        PDFKitView(pdfView: controller.pdfView)
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .bottom) {
                if controller.pageCount > 1 {
                    Text("\(controller.pageIndex + 1) of \(controller.pageCount)")
                        .font(.footnote.monospacedDigit())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 12)
                }
            }
            .overlay {
                if controller.failed {
                    ContentUnavailableView("Can't Open PDF", systemImage: "doc.richtext", description: Text("The file may be damaged."))
                } else if controller.needsPassword && !controller.isLocked {
                    ContentUnavailableView {
                        Label("Locked PDF", systemImage: "lock.doc")
                    } description: {
                        Text("Enter the password to view this document.")
                    } actions: {
                        Button("Unlock") { controller.isLocked = true }
                            .buttonStyle(.bordered)
                    }
                }
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Find", systemImage: "magnifyingglass") {
                        controller.showFind()
                    }
                    Menu {
                        Picker("Layout", selection: Binding(get: { controller.layout }, set: { controller.setLayout($0) })) {
                            ForEach(PDFController.Layout.allCases) { layout in
                                Label(layout.title, systemImage: layout.symbol).tag(layout)
                            }
                        }
                    } label: {
                        Label("Layout", systemImage: controller.layout.symbol)
                    }
                    ShareLink(item: item.url)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .PDFViewPageChanged, object: controller.pdfView)) { _ in
                controller.updatePageIndex()
            }
            .task {
                controller.load(item.url)
            }
            .alert("Password Required", isPresented: $controller.isLocked) {
                SecureField("Password", text: $password)
                Button("Cancel", role: .cancel) {}
                Button("Unlock") {
                    let success = controller.unlock(with: password)
                    password = ""
                    if !success {
                        // Ask again once this alert has finished dismissing.
                        Task { controller.isLocked = true }
                    }
                }
            } message: {
                Text("“\(item.name)” is password protected.")
            }
    }
}

@MainActor
@Observable
final class PDFController {
    enum Layout: String, CaseIterable, Identifiable {
        case continuous, singlePage, twoPages

        var id: Self { self }

        var title: String {
            switch self {
            case .continuous: "Continuous Scroll"
            case .singlePage: "Single Page"
            case .twoPages: "Two Pages"
            }
        }

        var symbol: String {
            switch self {
            case .continuous: "rectangle.grid.1x2"
            case .singlePage: "rectangle.portrait"
            case .twoPages: "rectangle.split.2x1"
            }
        }
    }

    let pdfView: PDFView
    private(set) var pageIndex = 0
    private(set) var pageCount = 0
    private(set) var layout = Layout.continuous
    private(set) var failed = false
    private(set) var needsPassword = false
    /// Drives the password prompt.
    var isLocked = false

    init() {
        pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = .secondarySystemBackground
        pdfView.isFindInteractionEnabled = true
    }

    func load(_ url: URL) {
        guard pdfView.document == nil else { return }
        guard let document = PDFDocument(url: url) else {
            failed = true
            return
        }
        pdfView.document = document
        pageCount = document.pageCount
        needsPassword = document.isLocked
        isLocked = document.isLocked
    }

    func unlock(with password: String) -> Bool {
        guard let document = pdfView.document, document.unlock(withPassword: password) else { return false }
        // Reassign so PDFView redraws the now-readable pages.
        pdfView.document = nil
        pdfView.document = document
        pageCount = document.pageCount
        needsPassword = false
        return true
    }

    func updatePageIndex() {
        guard let page = pdfView.currentPage, let document = pdfView.document else { return }
        pageIndex = document.index(for: page)
    }

    func setLayout(_ layout: Layout) {
        self.layout = layout
        let page = pdfView.currentPage
        switch layout {
        case .continuous:
            pdfView.usePageViewController(false, withViewOptions: nil)
            pdfView.displayMode = .singlePageContinuous
        case .singlePage:
            pdfView.displayMode = .singlePage
            pdfView.usePageViewController(true, withViewOptions: nil)
        case .twoPages:
            pdfView.usePageViewController(false, withViewOptions: nil)
            pdfView.displayMode = .twoUpContinuous
        }
        pdfView.autoScales = true
        if let page { pdfView.go(to: page) }
    }

    func showFind() {
        let interaction: UIFindInteraction? = pdfView.findInteraction
        interaction?.presentFindNavigator(showingReplace: false)
    }
}

private struct PDFKitView: UIViewRepresentable {
    let pdfView: PDFView

    func makeUIView(context: Context) -> PDFView {
        pdfView
    }

    func updateUIView(_ view: PDFView, context: Context) {}
}
