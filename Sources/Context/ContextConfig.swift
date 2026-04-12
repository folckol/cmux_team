import Foundation

/// Configuration for the Team Context feature.
/// Loaded from the `context` block in cmux.json (global or project-level).
struct ContextConfig: Codable, Equatable {
    /// Whether the context feature is enabled.
    var enabled: Bool

    /// Path to the SQLite database.
    var dbPath: String?

    /// Path to the Unix socket.
    var socketPath: String?

    /// Whether to auto-inject context when launching Claude Code.
    var autoInject: Bool

    /// Categories to include in auto-injection.
    var injectCategories: [String]

    /// Maximum size of injected context in bytes.
    var maxInjectSize: Int

    /// Whether the knowledge graph feature is enabled.
    var graphEnabled: Bool

    /// Drag & drop settings.
    var dragDrop: DragDropConfig

    enum CodingKeys: String, CodingKey {
        case enabled
        case dbPath = "db_path"
        case socketPath = "socket_path"
        case autoInject = "auto_inject"
        case injectCategories = "inject_categories"
        case maxInjectSize = "max_inject_size"
        case graphEnabled = "graph_enabled"
        case dragDrop = "drag_drop"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        dbPath = try container.decodeIfPresent(String.self, forKey: .dbPath)
        socketPath = try container.decodeIfPresent(String.self, forKey: .socketPath)
        autoInject = try container.decodeIfPresent(Bool.self, forKey: .autoInject) ?? true
        injectCategories = try container.decodeIfPresent([String].self, forKey: .injectCategories) ?? ["env", "endpoints", "architecture"]
        maxInjectSize = try container.decodeIfPresent(Int.self, forKey: .maxInjectSize) ?? 4096
        graphEnabled = try container.decodeIfPresent(Bool.self, forKey: .graphEnabled) ?? true
        dragDrop = try container.decodeIfPresent(DragDropConfig.self, forKey: .dragDrop) ?? DragDropConfig()
    }

    init() {
        enabled = true
        dbPath = nil
        socketPath = nil
        autoInject = true
        injectCategories = ["env", "endpoints", "architecture"]
        maxInjectSize = 4096
        graphEnabled = true
        dragDrop = DragDropConfig()
    }
}

/// Configuration for drag & drop code-to-context.
struct DragDropConfig: Codable, Equatable {
    /// Whether drag & drop is enabled.
    var enabled: Bool

    /// Whether to auto-close the Claude terminal after processing.
    var autoCloseTerminal: Bool

    /// Height of the ephemeral terminal as a fraction of the workspace (0.0 - 1.0).
    var terminalHeight: Double

    /// Custom path to the transform prompt file.
    var transformPromptPath: String?

    enum CodingKeys: String, CodingKey {
        case enabled
        case autoCloseTerminal = "auto_close_terminal"
        case terminalHeight = "terminal_height"
        case transformPromptPath = "transform_prompt_path"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        autoCloseTerminal = try container.decodeIfPresent(Bool.self, forKey: .autoCloseTerminal) ?? true
        terminalHeight = try container.decodeIfPresent(Double.self, forKey: .terminalHeight) ?? 0.3
        transformPromptPath = try container.decodeIfPresent(String.self, forKey: .transformPromptPath)
    }

    init() {
        enabled = true
        autoCloseTerminal = true
        terminalHeight = 0.3
        transformPromptPath = nil
    }
}
