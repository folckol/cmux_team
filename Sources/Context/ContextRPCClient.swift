import Foundation

/// Low-level JSON-RPC client for the context daemon.
/// Supports Unix socket (local) and TCP (remote with token auth).
/// All network I/O happens off-main; only model mutations dispatch to main.
final class ContextRPCClient: @unchecked Sendable {

    enum ConnectionMode {
        case unixSocket(String)
        case tcp(host: String, port: Int, token: String)
    }

    private let mode: ConnectionMode
    private let queue = DispatchQueue(label: "com.cmux.context-rpc", qos: .userInitiated)
    private var nextID: Int = 1
    private let lock = NSLock()
    // Active project id is auto-injected into every request's params.
    // Empty string means "let the daemon fall back to the default project".
    private var _currentProjectId: String = ""
    // Caller user id auto-injected so daemon can authorize per-user
    // (admin checks, project membership). Empty means "anonymous".
    private var _currentUserId: String = ""

    init(socketPath: String) {
        self.mode = .unixSocket(socketPath)
    }

    init(host: String, port: Int, token: String) {
        self.mode = .tcp(host: host, port: port, token: token)
    }

    // MARK: - Project scope

    func setCurrentProjectId(_ id: String) {
        lock.lock()
        _currentProjectId = id
        lock.unlock()
    }

    private func currentProjectId() -> String {
        lock.lock()
        defer { lock.unlock() }
        return _currentProjectId
    }

    func setCurrentUserId(_ id: String) {
        lock.lock()
        _currentUserId = id
        lock.unlock()
    }

    private func currentUserId() -> String {
        lock.lock()
        defer { lock.unlock() }
        return _currentUserId
    }

    // MARK: - Access control

    func setUserAdmin(id: String, isAdmin: Bool, completion: @escaping (Result<ContextUser, ContextRPCError>) -> Void) {
        call(method: "context.user.set_admin",
             params: ["id": id, "is_admin": isAdmin] as [String: Any],
             completion: completion)
    }

    func projectSetPassword(id: String, password: String, completion: @escaping (Result<Void, ContextRPCError>) -> Void) {
        callVoid(method: "context.project.set_password",
                 params: ["id": id, "password": password],
                 completion: completion)
    }

    func projectJoin(id: String, password: String, role: String = "", completion: @escaping (Result<Void, ContextRPCError>) -> Void) {
        callVoid(method: "context.project.join",
                 params: ["id": id, "password": password, "role": role],
                 completion: completion)
    }

    func projectLeave(id: String, userId: String = "", completion: @escaping (Result<Void, ContextRPCError>) -> Void) {
        callVoid(method: "context.project.leave",
                 params: ["id": id, "user_id": userId],
                 completion: completion)
    }

    func projectMembers(id: String, completion: @escaping (Result<[ContextProjectMember], ContextRPCError>) -> Void) {
        call(method: "context.project.members", params: ["id": id]) {
            (result: Result<MembersResponse, ContextRPCError>) in
            completion(result.map(\.members))
        }
    }

    // MARK: - Projects

    func projectList(completion: @escaping (Result<[ContextProject], ContextRPCError>) -> Void) {
        call(method: "context.project.list", params: [:]) { (result: Result<ProjectListResponse, ContextRPCError>) in
            completion(result.map(\.projects))
        }
    }

    func projectCreate(name: String, author: String = "", completion: @escaping (Result<ContextProject, ContextRPCError>) -> Void) {
        call(method: "context.project.create", params: ["name": name, "author": author], completion: completion)
    }

    func projectRename(id: String, name: String, author: String = "", completion: @escaping (Result<ContextProject, ContextRPCError>) -> Void) {
        call(method: "context.project.rename", params: ["id": id, "name": name, "author": author], completion: completion)
    }

    func projectDelete(id: String, author: String = "", completion: @escaping (Result<Void, ContextRPCError>) -> Void) {
        callVoid(method: "context.project.delete", params: ["id": id, "author": author], completion: completion)
    }

    // MARK: - KV

    func kvGet(key: String, completion: @escaping (Result<ContextKVEntry, ContextRPCError>) -> Void) {
        call(method: "context.kv.get", params: ["key": key]) { (result: Result<ContextKVEntry, ContextRPCError>) in
            completion(result)
        }
    }

    func kvSet(key: String, value: String, category: String = "", tags: [String] = [], author: String = "", completion: @escaping (Result<ContextKVEntry, ContextRPCError>) -> Void) {
        call(method: "context.kv.set", params: [
            "key": key, "value": value, "category": category, "tags": tags, "author": author
        ] as [String: Any]) { (result: Result<ContextKVEntry, ContextRPCError>) in
            completion(result)
        }
    }

    func kvDelete(key: String, author: String = "", completion: @escaping (Result<Void, ContextRPCError>) -> Void) {
        callVoid(method: "context.kv.delete", params: ["key": key, "author": author], completion: completion)
    }

    func kvList(category: String = "", prefix: String = "", completion: @escaping (Result<[ContextKVEntry], ContextRPCError>) -> Void) {
        call(method: "context.kv.list", params: ["category": category, "prefix": prefix]) { (result: Result<KVListResponse, ContextRPCError>) in
            completion(result.map(\.entries))
        }
    }

    // MARK: - Documents

    func docGet(id: String, completion: @escaping (Result<ContextDocument, ContextRPCError>) -> Void) {
        call(method: "context.doc.get", params: ["id": id], completion: completion)
    }

    func docCreate(title: String, body: String, category: String = "", tags: [String] = [], author: String = "", completion: @escaping (Result<ContextDocument, ContextRPCError>) -> Void) {
        call(method: "context.doc.create", params: [
            "title": title, "body": body, "category": category, "tags": tags, "author": author
        ] as [String: Any], completion: completion)
    }

    func docUpdate(id: String, title: String? = nil, body: String? = nil, category: String? = nil, tags: [String]? = nil, author: String = "", completion: @escaping (Result<ContextDocument, ContextRPCError>) -> Void) {
        var params: [String: Any] = ["id": id, "author": author]
        if let title { params["title"] = title }
        if let body { params["body"] = body }
        if let category { params["category"] = category }
        if let tags { params["tags"] = tags }
        call(method: "context.doc.update", params: params, completion: completion)
    }

    func docDelete(id: String, author: String = "", completion: @escaping (Result<Void, ContextRPCError>) -> Void) {
        callVoid(method: "context.doc.delete", params: ["id": id, "author": author], completion: completion)
    }

    func docList(category: String = "", tag: String = "", limit: Int = 50, offset: Int = 0, completion: @escaping (Result<[ContextDocument], ContextRPCError>) -> Void) {
        call(method: "context.doc.list", params: [
            "category": category, "tag": tag, "limit": limit, "offset": offset
        ] as [String: Any]) { (result: Result<DocListResponse, ContextRPCError>) in
            completion(result.map(\.documents))
        }
    }

    func docSearch(query: String, completion: @escaping (Result<[ContextDocument], ContextRPCError>) -> Void) {
        call(method: "context.doc.search", params: ["query": query]) { (result: Result<DocListResponse, ContextRPCError>) in
            completion(result.map(\.documents))
        }
    }

    // MARK: - Entities

    func entityCreate(type: String, name: String, properties: [String: Any] = [:], author: String = "", completion: @escaping (Result<ContextEntity, ContextRPCError>) -> Void) {
        call(method: "context.entity.create", params: [
            "type": type, "name": name, "properties": properties, "author": author
        ] as [String: Any], completion: completion)
    }

    func entityGet(id: String, completion: @escaping (Result<ContextEntity, ContextRPCError>) -> Void) {
        call(method: "context.entity.get", params: ["id": id], completion: completion)
    }

    func entityUpdate(id: String, name: String? = nil, properties: [String: Any]? = nil, author: String = "", completion: @escaping (Result<ContextEntity, ContextRPCError>) -> Void) {
        var params: [String: Any] = ["id": id, "author": author]
        if let name { params["name"] = name }
        if let properties { params["properties"] = properties }
        call(method: "context.entity.update", params: params, completion: completion)
    }

    func entityDelete(id: String, author: String = "", completion: @escaping (Result<Void, ContextRPCError>) -> Void) {
        callVoid(method: "context.entity.delete", params: ["id": id, "author": author], completion: completion)
    }

    func entityList(type: String = "", limit: Int = 100, completion: @escaping (Result<[ContextEntity], ContextRPCError>) -> Void) {
        call(method: "context.entity.list", params: ["type": type, "limit": limit] as [String: Any]) { (result: Result<EntityListResponse, ContextRPCError>) in
            completion(result.map(\.entities))
        }
    }

    // MARK: - Edges

    func edgeCreate(sourceId: String, targetId: String, relation: String, properties: [String: Any] = [:], author: String = "", completion: @escaping (Result<ContextEdge, ContextRPCError>) -> Void) {
        call(method: "context.edge.create", params: [
            "source_id": sourceId, "target_id": targetId, "relation": relation, "properties": properties, "author": author
        ] as [String: Any], completion: completion)
    }

    func edgeDelete(id: String, author: String = "", completion: @escaping (Result<Void, ContextRPCError>) -> Void) {
        callVoid(method: "context.edge.delete", params: ["id": id, "author": author], completion: completion)
    }

    // MARK: - Users

    func userList(completion: @escaping (Result<[ContextUser], ContextRPCError>) -> Void) {
        call(method: "context.user.list", params: [:]) { (result: Result<UserListResponse, ContextRPCError>) in
            completion(result.map(\.users))
        }
    }

    /// Server-wide user list (admin-only on the daemon side).
    func userListAll(completion: @escaping (Result<[ContextUser], ContextRPCError>) -> Void) {
        call(method: "context.user.list", params: ["all": true] as [String: Any]) {
            (result: Result<UserListResponse, ContextRPCError>) in
            completion(result.map(\.users))
        }
    }

    func userCreate(id: String = "", name: String, role: String, email: String = "", completion: @escaping (Result<ContextUser, ContextRPCError>) -> Void) {
        call(method: "context.user.create", params: [
            "id": id, "name": name, "role": role, "email": email
        ], completion: completion)
    }

    func userDelete(id: String, completion: @escaping (Result<Void, ContextRPCError>) -> Void) {
        callVoid(method: "context.user.delete", params: ["id": id], completion: completion)
    }

    // MARK: - Locks

    func lockAcquire(kind: String, targetId: String, userId: String, userName: String, completion: @escaping (Result<Void, ContextRPCError>) -> Void) {
        callVoid(method: "context.lock.acquire", params: [
            "kind": kind, "target_id": targetId, "user_id": userId, "user_name": userName
        ], completion: completion)
    }

    func lockHeartbeat(kind: String, targetId: String, userId: String, completion: @escaping (Result<Void, ContextRPCError>) -> Void) {
        callVoid(method: "context.lock.heartbeat", params: [
            "kind": kind, "target_id": targetId, "user_id": userId
        ], completion: completion)
    }

    func lockRelease(kind: String, targetId: String, userId: String, completion: @escaping (Result<Void, ContextRPCError>) -> Void) {
        callVoid(method: "context.lock.release", params: [
            "kind": kind, "target_id": targetId, "user_id": userId
        ], completion: completion)
    }

    func lockList(completion: @escaping (Result<[ContextLock], ContextRPCError>) -> Void) {
        call(method: "context.lock.list", params: [:]) { (result: Result<LockListResponse, ContextRPCError>) in
            completion(result.map(\.locks))
        }
    }

    // MARK: - Events

    func eventList(limit: Int = 50, userId: String = "", completion: @escaping (Result<[ContextEvent], ContextRPCError>) -> Void) {
        call(method: "context.event.list", params: [
            "limit": limit, "user_id": userId
        ] as [String: Any]) { (result: Result<EventListResponse, ContextRPCError>) in
            completion(result.map(\.events))
        }
    }

    func edgeList(entityId: String = "", relation: String = "", direction: String = "", completion: @escaping (Result<[ContextEdge], ContextRPCError>) -> Void) {
        call(method: "context.edge.list", params: [
            "entity_id": entityId, "relation": relation, "direction": direction
        ]) { (result: Result<EdgeListResponse, ContextRPCError>) in
            completion(result.map(\.edges))
        }
    }

    // MARK: - Search & Export

    func search(query: String, completion: @escaping (Result<[ContextSearchResult], ContextRPCError>) -> Void) {
        call(method: "context.search", params: ["query": query]) { (result: Result<SearchResponse, ContextRPCError>) in
            completion(result.map(\.results))
        }
    }

    func export(completion: @escaping (Result<Data, ContextRPCError>) -> Void) {
        queue.async { [self] in
            do {
                let respData = try sendRaw(method: "context.export", params: [:])
                completion(.success(respData))
            } catch let error as ContextRPCError {
                completion(.failure(error))
            } catch {
                completion(.failure(.connectionFailed(error.localizedDescription)))
            }
        }
    }

    // MARK: - Async wrappers

    func kvGet(key: String) async throws -> ContextKVEntry {
        try await withCheckedThrowingContinuation { cont in
            kvGet(key: key) { cont.resume(with: $0) }
        }
    }

    func kvSet(key: String, value: String, category: String = "", tags: [String] = []) async throws -> ContextKVEntry {
        try await withCheckedThrowingContinuation { cont in
            kvSet(key: key, value: value, category: category, tags: tags) { cont.resume(with: $0) }
        }
    }

    func kvList(category: String = "", prefix: String = "") async throws -> [ContextKVEntry] {
        try await withCheckedThrowingContinuation { cont in
            kvList(category: category, prefix: prefix) { cont.resume(with: $0) }
        }
    }

    func docList(category: String = "", tag: String = "") async throws -> [ContextDocument] {
        try await withCheckedThrowingContinuation { cont in
            docList(category: category, tag: tag) { cont.resume(with: $0) }
        }
    }

    func docSearch(query: String) async throws -> [ContextDocument] {
        try await withCheckedThrowingContinuation { cont in
            docSearch(query: query) { cont.resume(with: $0) }
        }
    }

    func entityList(type: String = "") async throws -> [ContextEntity] {
        try await withCheckedThrowingContinuation { cont in
            entityList(type: type) { cont.resume(with: $0) }
        }
    }

    func edgeList(entityId: String = "") async throws -> [ContextEdge] {
        try await withCheckedThrowingContinuation { cont in
            edgeList(entityId: entityId) { cont.resume(with: $0) }
        }
    }

    func search(query: String) async throws -> [ContextSearchResult] {
        try await withCheckedThrowingContinuation { cont in
            search(query: query) { cont.resume(with: $0) }
        }
    }

    // MARK: - Low-level transport

    private func call<T: Decodable>(method: String, params: [String: Any], completion: @escaping (Result<T, ContextRPCError>) -> Void) {
        queue.async { [self] in
            do {
                let data = try sendRaw(method: method, params: params)
                let resp = try JSONDecoder().decode(RPCTypedResponse<T>.self, from: data)
                if resp.ok, let result = resp.result {
                    completion(.success(result))
                } else if let error = resp.error {
                    completion(.failure(.serverError(code: error.code, message: error.message)))
                } else {
                    completion(.failure(.unknownError))
                }
            } catch let error as ContextRPCError {
                completion(.failure(error))
            } catch {
                completion(.failure(.decodingFailed(error.localizedDescription)))
            }
        }
    }

    private func callVoid(method: String, params: [String: Any], completion: @escaping (Result<Void, ContextRPCError>) -> Void) {
        queue.async { [self] in
            do {
                let data = try sendRaw(method: method, params: params)
                let resp = try JSONDecoder().decode(RPCBaseResponse.self, from: data)
                if resp.ok {
                    completion(.success(()))
                } else if let error = resp.error {
                    completion(.failure(.serverError(code: error.code, message: error.message)))
                } else {
                    completion(.failure(.unknownError))
                }
            } catch let error as ContextRPCError {
                completion(.failure(error))
            } catch {
                completion(.failure(.connectionFailed(error.localizedDescription)))
            }
        }
    }

    private func sendRaw(method: String, params: [String: Any]) throws -> Data {
        let id = nextRequestID()

        let fd: Int32
        switch mode {
        case .unixSocket(let path):
            fd = try connectUnixSocket(path: path)
        case .tcp(let host, let port, let token):
            fd = try connectTCP(host: host, port: port)
            // Authenticate
            try sendAuthRequest(fd: fd, token: token)
        }
        defer { close(fd) }

        // Auto-inject project_id (unless caller already set it, or this is a
        // non-scoped method like auth / ping / project management).
        var finalParams = params
        if !isProjectScopeless(method: method) && finalParams["project_id"] == nil {
            let pid = currentProjectId()
            if !pid.isEmpty {
                finalParams["project_id"] = pid
            }
        }
        // Auto-inject caller_user_id so the daemon can authorize per-user
        // (admin checks, project membership). Only when explicitly set.
        if finalParams["caller_user_id"] == nil {
            let uid = currentUserId()
            if !uid.isEmpty {
                finalParams["caller_user_id"] = uid
            }
        }

        // Build and send request
        let request: [String: Any] = ["id": id, "method": method, "params": finalParams]
        let requestData = try JSONSerialization.data(withJSONObject: request)
        var line = requestData
        line.append(contentsOf: [UInt8(ascii: "\n")])

        let sent = line.withUnsafeBytes { ptr in
            send(fd, ptr.baseAddress, ptr.count, 0)
        }
        guard sent == line.count else {
            throw ContextRPCError.connectionFailed("send() incomplete")
        }

        // Receive response
        var responseData = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            responseData.append(contentsOf: buf[0..<n])
            if buf[0..<n].contains(UInt8(ascii: "\n")) { break }
        }

        guard !responseData.isEmpty else {
            throw ContextRPCError.connectionFailed("empty response")
        }

        return responseData
    }

    private func connectUnixSocket(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ContextRPCError.connectionFailed("socket() failed") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw ContextRPCError.connectionFailed("socket path too long")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for (i, byte) in pathBytes.enumerated() { dest[i] = byte }
            }
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else {
            close(fd)
            throw ContextRPCError.connectionFailed("connect() failed: \(String(cString: strerror(errno)))")
        }
        return fd
    }

    private func connectTCP(host: String, port: Int) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ContextRPCError.connectionFailed("tcp socket() failed") }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        if inet_pton(AF_INET, host, &addr.sin_addr) != 1 {
            close(fd)
            throw ContextRPCError.connectionFailed("invalid host: \(host)")
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else {
            close(fd)
            throw ContextRPCError.connectionFailed("tcp connect failed: \(String(cString: strerror(errno)))")
        }
        return fd
    }

    private func sendAuthRequest(fd: Int32, token: String) throws {
        let authReq: [String: Any] = ["id": 0, "method": "auth", "params": ["token": token]]
        var data = try JSONSerialization.data(withJSONObject: authReq)
        data.append(UInt8(ascii: "\n"))
        let sent = data.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        guard sent == data.count else { throw ContextRPCError.connectionFailed("auth send failed") }

        // Read auth response
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = recv(fd, &buf, buf.count, 0)
        guard n > 0 else { throw ContextRPCError.connectionFailed("auth response empty") }
        let respData = Data(buf[0..<n])
        if let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
           json["ok"] as? Bool != true {
            let msg = (json["error"] as? [String: Any])?["message"] as? String ?? "auth failed"
            throw ContextRPCError.serverError(code: "auth_failed", message: msg)
        }
    }

    /// Methods that must not receive an auto-injected project_id.
    /// These are either connection-level (auth, ping, hello) or manage projects themselves.
    private func isProjectScopeless(method: String) -> Bool {
        switch method {
        case "auth", "ping", "hello",
             "context.project.list", "context.project.create",
             "context.project.rename", "context.project.delete",
             "context.project.set_password", "context.project.join",
             "context.project.leave", "context.project.members",
             "context.user.list", "context.user.create", "context.user.get",
             "context.user.delete", "context.user.set_admin":
            return true
        default:
            return false
        }
    }

    private func nextRequestID() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let id = nextID
        nextID += 1
        return id
    }
}

// MARK: - Error type

enum ContextRPCError: Error, LocalizedError {
    case connectionFailed(String)
    case serverError(code: String, message: String)
    case decodingFailed(String)
    case unknownError

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .serverError(_, let msg): return msg
        case .decodingFailed(let msg): return "Decoding failed: \(msg)"
        case .unknownError: return "Unknown error"
        }
    }
}

// MARK: - Response types

private struct RPCErrorPayload: Codable {
    let code: String
    let message: String
}

private struct RPCBaseResponse: Codable {
    let id: Int?
    let ok: Bool
    let error: RPCErrorPayload?
}

private struct RPCTypedResponse<T: Decodable>: Decodable {
    let id: Int?
    let ok: Bool
    let result: T?
    let error: RPCErrorPayload?
}

private struct KVListResponse: Codable {
    let entries: [ContextKVEntry]
    let count: Int
}

private struct DocListResponse: Codable {
    let documents: [ContextDocument]
    let count: Int
}

private struct EntityListResponse: Codable {
    let entities: [ContextEntity]
    let count: Int
}

private struct EdgeListResponse: Codable {
    let edges: [ContextEdge]
    let count: Int
}

private struct SearchResponse: Codable {
    let results: [ContextSearchResult]
    let count: Int
}

private struct UserListResponse: Codable {
    let users: [ContextUser]
    let count: Int
}

private struct LockListResponse: Codable {
    let locks: [ContextLock]
    let count: Int
}

private struct EventListResponse: Codable {
    let events: [ContextEvent]
    let count: Int
}

private struct ProjectListResponse: Codable {
    let projects: [ContextProject]
    let count: Int
}

private struct MembersResponse: Codable {
    let members: [ContextProjectMember]
    let count: Int
}
