import AppKit
import SwiftUI

/// Panel view for team context — wraps full UI in NSHostingView via NSViewRepresentable
/// to isolate SwiftUI rendering from cmux's portal system (prevents recursion crashes).
/// Same pattern as BrowserPanelView's WebViewRepresentable.
struct ContextPanelView: View {
    @ObservedObject var panel: ContextPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onRequestPanelFocus: () -> Void

    var body: some View {
        ContextPanelHostingWrapper(store: panel.contextStore, projectRoot: panel.projectRoot)
            .id(panel.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - NSViewRepresentable wrapper

/// Embeds ContextWindowView inside its own NSHostingView, breaking the
/// SwiftUI→AppKit→SwiftUI nesting that causes infinite recursion in the portal system.
private struct ContextPanelHostingWrapper: NSViewRepresentable {
    let store: ContextStore
    let projectRoot: String?

    func makeNSView(context: Context) -> ContextPanelHostView {
        let view = ContextPanelHostView()
        view.mountContent(store: store, projectRoot: projectRoot)
        return view
    }

    func updateNSView(_ nsView: ContextPanelHostView, context: Context) {
        // Content updates are handled by @ObservedObject inside the hosted SwiftUI view
    }
}

/// AppKit container that holds an isolated NSHostingView with the full context UI.
final class ContextPanelHostView: NSView {
    private var hostingView: NSHostingView<ContextWindowView>?

    func mountContent(store: ContextStore, projectRoot: String? = nil) {
        guard hostingView == nil else { return }
        let hosted = NSHostingView(rootView: ContextWindowView(store: store, projectRoot: projectRoot))
        hosted.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosted)
        NSLayoutConstraint.activate([
            hosted.topAnchor.constraint(equalTo: topAnchor),
            hosted.bottomAnchor.constraint(equalTo: bottomAnchor),
            hosted.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosted.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        hostingView = hosted
    }
}
