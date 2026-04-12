import Foundation
import Combine

/// A panel that displays the team context knowledge base.
/// Shows KV entries, documents, and knowledge graph entities with
/// editing capabilities and search.
@MainActor
final class ContextPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .context

    /// The workspace this panel belongs to.
    private(set) var workspaceId: UUID

    /// Reference to the shared context store.
    let contextStore: ContextStore

    /// Directory of the workspace/project — used to persist connection config.
    let projectRoot: String?

    /// Currently selected tab within the context panel.
    @Published var selectedTab: ContextPanelTab = .keyValue

    /// Search query.
    @Published var searchQuery: String = ""

    /// Title shown in the tab bar.
    @Published private(set) var displayTitle: String

    /// SF Symbol icon for the tab bar.
    var displayIcon: String? { "book.closed" }

    /// Token incremented to trigger focus flash animation.
    @Published private(set) var focusFlashToken: Int = 0

    /// Whether the panel has unsaved changes.
    var isDirty: Bool { false }

    // MARK: - Init

    init(workspaceId: UUID, contextStore: ContextStore, projectRoot: String? = nil) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.contextStore = contextStore
        self.projectRoot = projectRoot
        self.displayTitle = String(localized: "context.panel.title", defaultValue: "Team Context")

        contextStore.setProjectRoot(projectRoot)
        if let root = projectRoot,
           let config = ContextStore.loadProjectConfig(projectRoot: root) {
            contextStore.applyProjectConfig(config)
        } else {
            contextStore.applyProjectConfig(ContextStore.ProjectConfig(mode: "local", host: "", port: 9876, token: ""))
        }
    }

    // MARK: - Panel protocol

    func focus() {
        // Focus the search field or list depending on intent
    }

    func unfocus() {
        // No-op
    }

    func close() {
        // No-op, context store persists beyond panel lifetime
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        focusFlashToken += 1
    }

    // MARK: - Focus intent

    private(set) var lastFocusIntent: PanelFocusIntent?

    func captureFocusIntent() -> PanelFocusIntent? {
        return lastFocusIntent
    }

    func restoreFocusIntent(_ intent: PanelFocusIntent?) {
        lastFocusIntent = intent
    }
}

// MARK: - Tab enum

enum ContextPanelTab: String, CaseIterable, Identifiable {
    case keyValue
    case documents
    case graph
    case users
    case settings

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .keyValue: return String(localized: "context.tab.kv", defaultValue: "Key-Value")
        case .documents: return String(localized: "context.tab.docs", defaultValue: "Documents")
        case .graph: return String(localized: "context.tab.graph", defaultValue: "Graph")
        case .users: return String(localized: "context.tab.users", defaultValue: "Users")
        case .settings: return String(localized: "context.tab.settings", defaultValue: "Settings")
        }
    }

    var iconName: String {
        switch self {
        case .keyValue: return "key"
        case .documents: return "doc.text"
        case .graph: return "point.3.connected.trianglepath.dotted"
        case .users: return "person.2"
        case .settings: return "gearshape"
        }
    }
}
