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
    /// Server-wide user list. Populated only for admins (via refreshAllUsers),
    /// used by the Admin tab. Non-admins leave this empty.
    @Published var allUsers: [ContextUser] = []
    @Published var events: [ContextEvent] = []
    @Published var locks: [ContextLock] = []
    @Published var projects: [ContextProject] = []
    @Published var currentProjectId: String = ""
    @Published var currentProjectMembers: [ContextProjectMember] = []
    /// True when the daemon refused the last operation due to membership.
    /// UI uses this to flip into "Join this project" mode.
    @Published var notAMemberOfCurrentProject: Bool = false
    /// True when no user has identified themselves yet.
    var isUnidentified: Bool { (currentUser?.id ?? "").isEmpty }
    @Published var currentUser: ContextUser?
    @Published var isConnected: Bool = false
    @Published var lastError: String?

    /// Display name of the current project. "" / "default" → "Default".
    var currentProjectName: String {
        if currentProjectId.isEmpty || currentProjectId == "default" {
            return projects.first(where: { $0.id == "default" })?.name ?? "Default"
        }
        return projects.first(where: { $0.id == currentProjectId })?.name ?? currentProjectId
    }

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
        // Re-hydrate auto-inject state on the fresh client, otherwise the
        // first refreshes go out without caller_user_id / project_id and the
        // daemon returns identity_required, flipping the UI into the gated
        // state until the user manually re-identifies.
        if let uid = currentUser?.id, !uid.isEmpty {
            rpcClient.setCurrentUserId(uid)
        }
        if !currentProjectId.isEmpty {
            rpcClient.setCurrentProjectId(currentProjectId)
        }
        self.isConnected = false
        self.lastError = nil
        refresh()
    }

    /// Reconnect to local socket
    func connectToLocal(socketPath: String? = nil) {
        let path = socketPath ?? ContextStore.defaultSocketPath()
        self.rpcClient = ContextRPCClient(socketPath: path)
        if let uid = currentUser?.id, !uid.isEmpty {
            rpcClient.setCurrentUserId(uid)
        }
        if !currentProjectId.isEmpty {
            rpcClient.setCurrentProjectId(currentProjectId)
        }
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
        // projectId selects which team-context project to use on this connection.
        // Empty → daemon falls back to "default" (backward compatible).
        var projectId: String?

        enum CodingKeys: String, CodingKey {
            case mode, host, port, token
            case projectId = "project_id"
        }
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
        // Select project scope on the fresh client before the refresh kicks in.
        let pid = config.projectId ?? ""
        self.currentProjectId = pid
        rpcClient.setCurrentProjectId(pid)
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
            await refreshProjects()
            await refreshProjectMembers()
            await refreshKV()
            await refreshDocs()
            await refreshEntities()
            await refreshEdges()
            await refreshUsers()
            await refreshLocks()
        }
    }

    // MARK: - Projects

    func refreshProjects() {
        rpcClient.projectList { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let list):
                    self?.projects = list
                    // If no current project is selected but default exists, lock in default.
                    if let self, self.currentProjectId.isEmpty, list.contains(where: { $0.id == "default" }) {
                        self.currentProjectId = "default"
                        self.rpcClient.setCurrentProjectId("default")
                    }
                case .failure(let error):
                    self?.lastError = error.localizedDescription
                }
            }
        }
    }

    /// Switch active project: change scope and reload all per-project caches.
    /// Connection is reused (no reconnect).
    func switchProject(id: String) {
        guard id != currentProjectId else { return }
        currentProjectId = id
        rpcClient.setCurrentProjectId(id)
        // Persist selection to the per-workspace config so next launch sticks.
        if let root = projectRoot, var cfg = ContextStore.loadProjectConfig(projectRoot: root) {
            cfg.projectId = id
            try? ContextStore.saveProjectConfig(projectRoot: root, config: cfg)
        }
        kvEntries = []; documents = []; entities = []; edges = []; locks = []; events = []
        refresh()
    }

    func createProject(name: String, completion: ((Result<ContextProject, ContextRPCError>) -> Void)? = nil) {
        rpcClient.projectCreate(name: name, author: currentAuthorId) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let project):
                    self?.refreshProjects()
                    self?.switchProject(id: project.id)
                    completion?(.success(project))
                case .failure(let error):
                    self?.lastError = error.localizedDescription
                    completion?(.failure(error))
                }
            }
        }
    }

    func renameProject(id: String, name: String) {
        rpcClient.projectRename(id: id, name: name, author: currentAuthorId) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success: self?.refreshProjects()
                case .failure(let error): self?.lastError = error.localizedDescription
                }
            }
        }
    }

    func deleteProject(id: String) {
        rpcClient.projectDelete(id: id, author: currentAuthorId) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    if self?.currentProjectId == id {
                        self?.switchProject(id: "default")
                    }
                    self?.refreshProjects()
                case .failure(let error):
                    self?.lastError = error.localizedDescription
                }
            }
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

    // MARK: - Project system prompt (.cmux_team/system_prompt.md)

    static let defaultSystemPrompt = """
    # Team Context Rules

    После каждого изменения кода, если это затронуло блок связанный с должностью другого пользователя в команде, смотри есть ли соответствующая папка -> файл согласно модулю над которым ты работаешь и принимай решение, нужно ли создать / отредактировать данный блок чтобы член команды понимал что были произведены какие либо изменения в системе на нашей стороне и мог их интегрировать.

    ## Как это делать

    1. Определи, к чьей зоне ответственности относится изменённый код (роль: frontend / backend / devops / …). Список членов команды и их ролей — выше, в блоке Team Members.
    2. Если изменение затрагивает контракт или публичный интерфейс (API endpoint, формат данных, config, env-переменная, схема БД, событие шины, зависимость на внешний сервис) — **обнови общий контекст**:
       - `cmux context set <key> "<value>" -c <category>` — для коротких значений (URL, флаги, имена очередей).
       - `cmux context doc create/update -t "<title>" -f <file> -c <category>` — для описаний API, ADR, инструкций.
       - `cmux context entity create --type service --name <name>` и связи `depends_on` / `uses` — если появился новый компонент или зависимость.
    3. Перед записью покажи preview того, что собираешься сохранить.
    4. Атрибуция применится автоматически из `.cmux_team/me.json`.
    5. Если не уверен, кого касается изменение — спроси пользователя, а не пропускай.

    ## Журнал и координация
    - Прежде чем начать крупное изменение, проверь `cmux context events -n 30` — возможно, коллега только что трогал эту же область.
    - `cmux context locks` показывает, что сейчас кем редактируется в панели — не конфликтуй.

    ## Чего делать НЕ нужно
    - Никогда не клади в контекст секреты (токены, пароли, приватные ключи). Только ссылки на vault.
    - Не дублируй то, что уже есть — сначала `cmux context search <query>`.
    """

    static func systemPromptURL(projectRoot: String) -> URL {
        URL(fileURLWithPath: projectRoot)
            .appendingPathComponent(".cmux_team", isDirectory: true)
            .appendingPathComponent("system_prompt.md")
    }

    static func loadSystemPrompt(projectRoot: String) -> String {
        let url = systemPromptURL(projectRoot: projectRoot)
        if let data = try? Data(contentsOf: url), let s = String(data: data, encoding: .utf8), !s.isEmpty {
            return s
        }
        return defaultSystemPrompt
    }

    static func saveSystemPrompt(projectRoot: String, text: String) throws {
        let url = systemPromptURL(projectRoot: projectRoot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.data(using: .utf8)?.write(to: url, options: .atomic)
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
            self.currentUser = ContextUser(id: me.userId, name: me.name, role: me.role, email: me.email, isAdmin: false, createdAt: 0)
            self.rpcClient.setCurrentUserId(me.userId)
        } else {
            self.currentUser = nil
            self.rpcClient.setCurrentUserId("")
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
                    self?.rpcClient.setCurrentUserId(user.id)
                    if let root = self?.projectRoot {
                        let me = Me(userId: user.id, name: user.name, role: user.role, email: user.email)
                        try? ContextStore.saveMe(projectRoot: root, me: me)
                    }
                    self?.refresh()
                case .failure(let error):
                    self?.lastError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Access control wrappers

    /// True iff the currently identified user is a server-wide admin.
    var isCurrentUserAdmin: Bool { currentUser?.isAdmin == true }

    /// True iff the active project belongs to the currently identified user.
    var isOwnerOfCurrentProject: Bool {
        guard let me = currentUser else { return false }
        let pid = currentProjectId.isEmpty ? "default" : currentProjectId
        return projects.first(where: { $0.id == pid })?.createdBy == me.id
    }

    func setUserAdmin(id: String, isAdmin: Bool) {
        rpcClient.setUserAdmin(id: id, isAdmin: isAdmin) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success: self?.refreshUsers()
                case .failure(let err): self?.lastError = err.localizedDescription
                }
            }
        }
    }

    func setProjectPassword(id: String, password: String, completion: ((Result<Void, ContextRPCError>) -> Void)? = nil) {
        rpcClient.projectSetPassword(id: id, password: password) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self?.refreshProjects()
                    completion?(.success(()))
                case .failure(let err):
                    self?.lastError = err.localizedDescription
                    completion?(.failure(err))
                }
            }
        }
    }

    func joinProject(id: String, password: String, role: String = "", completion: ((Result<Void, ContextRPCError>) -> Void)? = nil) {
        rpcClient.projectJoin(id: id, password: password, role: role) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self?.notAMemberOfCurrentProject = false
                    self?.switchProject(id: id)
                    completion?(.success(()))
                case .failure(let err):
                    self?.lastError = err.localizedDescription
                    completion?(.failure(err))
                }
            }
        }
    }

    func leaveProject(id: String, userId: String = "") {
        rpcClient.projectLeave(id: id, userId: userId) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshProjectMembers()
                self?.refreshProjects()
            }
        }
    }

    func refreshProjectMembers() {
        let pid = currentProjectId.isEmpty ? "default" : currentProjectId
        rpcClient.projectMembers(id: pid) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let members):
                    self?.currentProjectMembers = members
                    self?.notAMemberOfCurrentProject = false
                case .failure(let err):
                    if case .serverError(let code, _) = err, code == "not_a_member" || code == "identity_required" {
                        self?.notAMemberOfCurrentProject = true
                        self?.currentProjectMembers = []
                    } else {
                        self?.lastError = err.localizedDescription
                    }
                }
            }
        }
    }

    /// Returns true when the error means "you can't access this project"
    /// — used by every refresh* to flip into the gated UI without spamming
    /// red error toasts. Admins never get gated; if we see this error for an
    /// admin it's a stale caller_user_id and a retry will resolve it.
    private func handleAccessError(_ error: ContextRPCError) -> Bool {
        if case .serverError(let code, _) = error,
           code == "not_a_member" || code == "identity_required" {
            if isCurrentUserAdmin {
                // Admin sees everything — don't flip the gate. The refresh
                // that triggered this likely raced init; next tick will
                // succeed with caller_user_id populated.
                return true
            }
            self.notAMemberOfCurrentProject = true
            self.kvEntries = []; self.documents = []; self.entities = []
            self.edges = []; self.events = []; self.locks = []
            self.currentProjectMembers = []
            return true
        }
        return false
    }

    func refreshKV(category: String = "") {
        rpcClient.kvList(category: category) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let entries):
                    self?.kvEntries = entries
                    self?.isConnected = true
                    self?.lastError = nil
                    self?.notAMemberOfCurrentProject = false
                case .failure(let error):
                    if self?.handleAccessError(error) == true { return }
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
                    if self?.handleAccessError(error) == true { return }
                    self?.lastError = error.localizedDescription
                }
            }
        }
    }

    /// Server-wide user list for the Admin tab. Daemon enforces admin-only.
    func refreshAllUsers() {
        rpcClient.userListAll { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let users):
                    self?.allUsers = users
                case .failure(let error):
                    // Silently drop non-admin refusals so the store stays quiet
                    // for non-admin users — they simply won't have an Admin tab.
                    if case .serverError(let code, _) = error, code == "forbidden" {
                        self?.allUsers = []
                        return
                    }
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
