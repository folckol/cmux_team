import Foundation
import Combine

/// Main observable model for team context data.
/// Holds cached state and communicates with the context daemon.
/// Per socket threading policy: RPC calls off-main, minimal UI mutations via main.async.
@MainActor
final class ContextStore: ObservableObject {

    @Published var kvEntries: [ContextKVEntry] = []
    @Published var documents: [ContextDocument] = []
    @Published var entities: [ContextEntity] = []
    @Published var edges: [ContextEdge] = []
    @Published var searchResults: [ContextSearchResult] = []
    @Published var users: [ContextUser] = []
    @Published var events: [ContextEvent] = []
    @Published var locks: [ContextLock] = []
    @Published var currentUser: ContextUser?
    @Published var isConnected: Bool = false
    @Published var lastError: String?

    private var rpcClient: ContextRPCClient
    private(set) var projectRoot: String?
    private var heartbeatTimers: [String: Timer] = [:]

    // Exposed so views can pass `author` into mutations. Empty when unidentified.
    var currentAuthorId: String { currentUser?.id ?? "" }
    var currentAuthorName: String { currentUser?.name ?? "" }

    init(socketPath: String? = nil) {
        let defaults = UserDefaults.standard
        let mode = defaults.string(forKey: "context.connection.mode") ?? "local"
        if mode == "remote",
           let host = defaults.string(forKey: "context.connection.host"), !host.isEmpty,
           let portStr = defaults.string(forKey: "context.connection.port"), let port = Int(portStr),
           let token = defaults.string(forKey: "context.connection.token"), !token.isEmpty {
            self.rpcClient = ContextRPCClient(host: host, port: port, token: token)
        } else {
            let path = socketPath ?? ContextStore.defaultSocketPath()
            self.rpcClient = ContextRPCClient(socketPath: path)
        }
    }

    init(host: String, port: Int, token: String) {
        self.rpcClient = ContextRPCClient(host: host, port: port, token: token)
    }

    /// Reconnect to a different server
    func connectToServer(host: String, port: Int, token: String) {
        self.rpcClient = ContextRPCClient(host: host, port: port, token: token)
        self.isConnected = false
        self.lastError = nil
        refresh()
    }

    /// Reconnect to local socket
    func connectToLocal(socketPath: String? = nil) {
        let path = socketPath ?? ContextStore.defaultSocketPath()
        self.rpcClient = ContextRPCClient(socketPath: path)
        self.isConnected = false
        self.lastError = nil
        refresh()
    }

    // MARK: - Per-project config (.cmux_team/connection.json)

    struct ProjectConfig: Codable {
        var mode: String       // "local" or "remote"
        var host: String
        var port: Int
        var token: String
    }

    static func projectConfigURL(projectRoot: String) -> URL {
        URL(fileURLWithPath: projectRoot)
            .appendingPathComponent(".cmux_team", isDirectory: true)
            .appendingPathComponent("connection.json")
    }

    static func loadProjectConfig(projectRoot: String) -> ProjectConfig? {
        let url = projectConfigURL(projectRoot: projectRoot)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ProjectConfig.self, from: data)
    }

    static func saveProjectConfig(projectRoot: String, config: ProjectConfig) throws {
        let url = projectConfigURL(projectRoot: projectRoot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(config)
        try data.write(to: url, options: .atomic)
    }

    /// Apply a project config: switch transport and refresh. Also mirrors to UserDefaults for UI fields.
    func applyProjectConfig(_ config: ProjectConfig) {
        let defaults = UserDefaults.standard
        defaults.set(config.mode, forKey: "context.connection.mode")
        defaults.set(config.host, forKey: "context.connection.host")
        defaults.set(String(config.port), forKey: "context.connection.port")
        defaults.set(config.token, forKey: "context.connection.token")
        if config.mode == "remote", !config.host.isEmpty, !config.token.isEmpty {
            connectToServer(host: config.host, port: config.port, token: config.token)
        } else {
            connectToLocal()
        }
    }

    static func defaultSocketPath() -> String {
        if let env = ProcessInfo.processInfo.environment["CMUX_CONTEXT_SOCKET_PATH"] {
            return env
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.config/cmux/context.sock"
    }

    // MARK: - Refresh all data

    func refresh() {
        Task {
            await refreshKV()
            await refreshDocs()
            await refreshEntities()
            await refreshEdges()
            await refreshUsers()
            await refreshLocks()
        }
    }

    // MARK: - Per-project "me.json" identity

    struct Me: Codable {
        var userId: String
        var name: String
        var role: String
        var email: String
        enum CodingKeys: String, CodingKey {
            case userId = "user_id"
            case name, role, email
        }
    }

    static func meURL(projectRoot: String) -> URL {
        URL(fileURLWithPath: projectRoot)
            .appendingPathComponent(".cmux_team", isDirectory: true)
            .appendingPathComponent("me.json")
    }

    static func loadMe(projectRoot: String) -> Me? {
        let url = meURL(projectRoot: projectRoot)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Me.self, from: data)
    }

    static func saveMe(projectRoot: String, me: Me) throws {
        let url = meURL(projectRoot: projectRoot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(me)
        try data.write(to: url, options: .atomic)
    }

    func setProjectRoot(_ root: String?) {
        self.projectRoot = root
        if let root, let me = ContextStore.loadMe(projectRoot: root) {
            self.currentUser = ContextUser(id: me.userId, name: me.name, role: me.role, email: me.email, createdAt: 0)
        } else {
            self.currentUser = nil
        }
    }

    /// Identify as a user: saves `.cmux_team/me.json` AND ensures user exists on daemon.
    func identifyAs(name: String, role: String, email: String = "") {
        let uid = currentUser?.id ?? UUID().uuidString
        rpcClient.userCreate(id: uid, name: name, role: role, email: email) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let user):
                    self?.currentUser = user
                    if let root = self?.projectRoot {
                        let me = Me(userId: user.id, name: user.name, role: user.role, email: user.email)
                        try? ContextStore.saveMe(projectRoot: root, me: me)
                    }
                    self?.refreshUsers()
                case .failure(let error):
                    self?.lastError = error.localizedDescription
                }
            }
        }
    }

    func refreshKV(category: String = "") {
        rpcClient.kvList(category: category) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let entries):
                    self?.kvEntries = entries
                    self?.isConnected = true
                    self?.lastError = nil
                case .failure(let error):
                    self?.lastError = error.localizedDescription
                    self?.isConnected = false
                }
            }
        }
    }

    func refreshDocs(category: String = "") {
        rpcClient.docList(category: category) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let docs):
                    self?.documents = docs
                case .failure(let error):
                    self?.lastError = error.localizedDescription
                }
            }
        }
    }

    func refreshEntities(type: String = "") {
        rpcClient.entityList(type: type) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let entities):
                    self?.entities = entities
                case .failure(let error):
                    self?.lastError = error.localizedDescription
                }
            }
        }
    }

    func refreshEdges() {
        rpcClient.edgeList { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let edges):
                    self?.edges = edges
                case .failure(let error):
                    self?.lastError = error.localizedDescription
                }
            }
        }
    }

    func refreshUsers() {
        rpcClient.userList { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let users):
                    self?.users = users
                case .failure(let error):
                    self?.lastError = error.localizedDescription
                }
            }
        }
    }

    func refreshEvents(limit: Int = 50) {
        rpcClient.eventList(limit: limit) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let events):
                    self?.events = events
                case .failure(let error):
                    self?.lastError = error.localizedDescription
                }
            }
        }
    }

    func refreshLocks() {
        rpcClient.lockList { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let locks):
                    self?.locks = locks
                case .failure(let error):
                    self?.lastError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Locks

    func lockHolder(kind: String, targetId: String) -> ContextLock? {
        let now = Int64(Date().timeIntervalSince1970)
        return locks.first { $0.kind == kind && $0.targetId == targetId && $0.expiresAt > now }
    }

    /// Acquire an edit lock for the given target. Starts a heartbeat timer.
    func acquireLock(kind: String, targetId: String, completion: @escaping (Bool, String?) -> Void) {
        let uid = currentAuthorId
        let name = currentAuthorName
        guard !uid.isEmpty else {
            completion(false, "Identify yourself in Users tab first")
            return
        }
        rpcClient.lockAcquire(kind: kind, targetId: targetId, userId: uid, userName: name) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self?.startHeartbeat(kind: kind, targetId: targetId)
                    self?.refreshLocks()
                    completion(true, nil)
                case .failure(let err):
                    completion(false, err.localizedDescription)
                }
            }
        }
    }

    func releaseLock(kind: String, targetId: String) {
        let uid = currentAuthorId
        let key = "\(kind):\(targetId)"
        heartbeatTimers[key]?.invalidate()
        heartbeatTimers.removeValue(forKey: key)
        rpcClient.lockRelease(kind: kind, targetId: targetId, userId: uid) { [weak self] _ in
            DispatchQueue.main.async { self?.refreshLocks() }
        }
    }

    private func startHeartbeat(kind: String, targetId: String) {
        let key = "\(kind):\(targetId)"
        heartbeatTimers[key]?.invalidate()
        let uid = currentAuthorId
        let timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.rpcClient.lockHeartbeat(kind: kind, targetId: targetId, userId: uid) { _ in }
        }
        heartbeatTimers[key] = timer
    }

    // MARK: - KV Operations

    func setKV(key: String, value: String, category: String = "", tags: [String] = []) {
        rpcClient.kvSet(key: key, value: value, category: category, tags: tags, author: currentAuthorId) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self?.refreshKV()
                case .failure(let error):
                    self?.lastError = error.localizedDescription
                }
            }
        }
    }

    func deleteKV(key: String) {
        rpcClient.kvDelete(key: key, author: currentAuthorId) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self?.refreshKV()
                case .failure(let error):
                    self?.lastError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Document Operations

    func createDoc(title: String, body: String, category: String = "", tags: [String] = []) {
        rpcClient.docCreate(title: title, body: body, category: category, tags: tags, author: currentAuthorId) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self?.refreshDocs()
                case .failure(let error):
                    self?.lastError = error.localizedDescription
                }
            }
        }
    }

    func updateDoc(id: String, title: String? = nil, body: String? = nil, category: String? = nil, tags: [String]? = nil) {
        rpcClient.docUpdate(id: id, title: title, body: body, category: category, tags: tags, author: currentAuthorId) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self?.refreshDocs()
                case .failure(let error):
                    self?.lastError = error.localizedDescription
                }
            }
        }
    }

    func deleteDoc(id: String) {
        rpcClient.docDelete(id: id, author: currentAuthorId) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self?.refreshDocs()
                case .failure(let error):
                    self?.lastError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Entity Operations

    func createEntity(type: String, name: String, properties: [String: Any] = [:]) {
        rpcClient.entityCreate(type: type, name: name, properties: properties, author: currentAuthorId) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self?.refreshEntities()
                case .failure(let error):
                    self?.lastError = error.localizedDescription
                }
            }
        }
    }

    func entityUpdate(id: String, name: String) {
        rpcClient.entityUpdate(id: id, name: name, author: currentAuthorId) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self?.refreshEntities()
                case .failure(let error):
                    self?.lastError = error.localizedDescription
                }
            }
        }
    }

    func deleteEntity(id: String) {
        rpcClient.entityDelete(id: id, author: currentAuthorId) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self?.refreshEntities()
                    self?.refreshEdges()
                case .failure(let error):
                    self?.lastError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Edge Operations

    func createEdge(sourceId: String, targetId: String, relation: String, properties: [String: Any] = [:]) {
        rpcClient.edgeCreate(sourceId: sourceId, targetId: targetId, relation: relation, properties: properties, author: currentAuthorId) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self?.refreshEdges()
                case .failure(let error):
                    self?.lastError = error.localizedDescription
                }
            }
        }
    }

    func deleteEdge(id: String) {
        rpcClient.edgeDelete(id: id, author: currentAuthorId) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self?.refreshEdges()
                case .failure(let error):
                    self?.lastError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Search

    func performSearch(query: String) {
        guard !query.isEmpty else {
            searchResults = []
            return
        }
        rpcClient.search(query: query) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let results):
                    self?.searchResults = results
                case .failure(let error):
                    self?.lastError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Summary for AI injection

    func generateContextSummary() async -> String {
        var lines: [String] = ["# Team Context Summary", ""]

        // KV entries
        if !kvEntries.isEmpty {
            lines.append("## Key-Value Entries")
            for entry in kvEntries {
                let catLabel = entry.category.isEmpty ? "" : " [\(entry.category)]"
                lines.append("- **\(entry.key)**\(catLabel): \(entry.value)")
            }
            lines.append("")
        }

        // Documents (titles only for summary)
        if !documents.isEmpty {
            lines.append("## Documents")
            for doc in documents {
                let catLabel = doc.category.isEmpty ? "" : " [\(doc.category)]"
                lines.append("- \(doc.title)\(catLabel)")
            }
            lines.append("")
        }

        // Entities
        if !entities.isEmpty {
            lines.append("## Knowledge Graph Entities")
            let grouped = Dictionary(grouping: entities, by: \.type)
            for (type, group) in grouped.sorted(by: { $0.key < $1.key }) {
                lines.append("### \(type.capitalized)s")
                for entity in group {
                    lines.append("- \(entity.name)")
                }
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }
}
