import SwiftUI

extension View {
    /// Adds a floating search field at the bottom of the screen while `isPresented` is true, and
    /// hides the tab bar on iPhone to make room for it. Pair with `SearchToolbarButton`.
    func searchPill(text: Binding<String>, isPresented: Binding<Bool>, prompt: String = "Search") -> some View {
        modifier(SearchPillModifier(text: text, isPresented: isPresented, prompt: prompt))
    }
}

/// The magnifying glass in the top-right corner that opens the search pill.
struct SearchToolbarButton: View {
    @Binding var isPresented: Bool

    var body: some View {
        Button("Search", systemImage: "magnifyingglass") {
            withAnimation(.snappy) { isPresented = true }
        }
        .accessibilityIdentifier("searchButton")
    }
}

private struct SearchPillModifier: ViewModifier {
    @Binding var text: String
    @Binding var isPresented: Bool
    let prompt: String

    @Environment(Router.self) private var router
    @Environment(\.usesSidebarLayout) private var usesSidebarLayout
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isPresented {
                    pill
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            // The pill takes the tab bar's place on iPhone. On iPad the bar sits at the top and stays.
            .toolbar(isPresented && !usesSidebarLayout ? .hidden : .automatic, for: .tabBar)
            .animation(.snappy, value: isPresented)
            .onChange(of: isPresented) { _, presented in
                router.isSearching = presented
                if presented {
                    isFocused = true
                } else {
                    text = ""
                }
            }
            .onDisappear {
                if isPresented { router.isSearching = false }
            }
    }

    private var pill: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .focused($isFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("searchField")
            Button {
                isFocused = false
                withAnimation(.snappy) { isPresented = false }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close Search")
            .accessibilityIdentifier("closeSearch")
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: 48)
        .modifier(GlassCapsule())
        .frame(maxWidth: 600)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}

/// Liquid Glass on iOS 26 and later, a material capsule before that.
struct GlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        }
    }
}
