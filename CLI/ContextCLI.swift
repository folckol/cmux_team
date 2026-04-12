import Foundation

/// CLI handler for `cmux context` subcommands.
/// Connects directly to the context daemon socket for all operations.
enum ContextCLI {

    static func run(args: [String]) -> Int32 {
        guard !args.isEmpty else {
            printUsage()
            return 2
        }

        let socketPath = resolveSocketPath()
        let _ = resolveAuthor() // warm cache, also ensures me.json is picked up early

        switch args[0] {
        case "show":
            return handleShow(socketPath: socketPath)
        case "get":
            guard args.count >= 2 else {
                fputs("Usage: cmux context get <key>\n", stderr)
                return 2
            }
            return handleGet(key: args[1], socketPath: socketPath)
        case "set":
            guard args.count >= 3 else {
                fputs("Usage: cmux context set <key> <value> [-c category] [--author <id>]\n", stderr)
                return 2
            }
            let tail = Array(args.dropFirst(3))
            let category = extractFlag(args: tail, flag: "-c")
            let author = resolveAuthor(explicit: extractFlag(args: tail, flag: "--author"))
            return handleSet(key: args[1], value: args[2], category: category ?? "", author: author, socketPath: socketPath)
        case "delete":
            guard args.count >= 2 else {
                fputs("Usage: cmux context delete <key> [--author <id>]\n", stderr)
                return 2
            }
            let author = resolveAuthor(explicit: extractFlag(args: Array(args.dropFirst(2)), flag: "--author"))
            return handleDelete(key: args[1], author: author, socketPath: socketPath)
        case "search":
            guard args.count >= 2 else {
                fputs("Usage: cmux context search <query>\n", stderr)
                return 2
            }
            return handleSearch(query: args[1...].joined(separator: " "), socketPath: socketPath)
        case "doc":
            return handleDoc(args: Array(args.dropFirst()), socketPath: socketPath)
        case "entity":
            return handleEntity(args: Array(args.dropFirst()), socketPath: socketPath)
        case "whoami":
            let uid = resolveAuthor()
            if uid.isEmpty {
                print("Not identified. Set .cmux_team/me.json or pass --author <id>, or open Team Context → Users → Identify as")
                return 1
            }
            if let resp = rpcCall(socketPath: socketPath, method: "context.user.get", params: ["id": uid]),
               let name = resp["name"] as? String {
                let role = resp["role"] as? String ?? ""
                print("\(name)\(role.isEmpty ? "" : " (\(role))") — id: \(uid)")
            } else {
                print(uid)
            }
            return 0
        case "users":
            guard let resp = rpcCall(socketPath: socketPath, method: "context.user.list", params: [:]),
                  let users = resp["users"] as? [[String: Any]] else {
                fputs("Error: could not list users\n", stderr)
                return 1
            }
            if users.isEmpty { print("No users"); return 0 }
            for u in users {
                let id = u["id"] as? String ?? ""
                let name = u["name"] as? String ?? ""
                let role = u["role"] as? String ?? ""
                print("\(id.prefix(8))  \(name)\(role.isEmpty ? "" : " — \(role)")")
            }
            return 0
        case "events":
            let limit = Int(extractFlag(args: Array(args.dropFirst()), flag: "-n") ?? "") ?? 20
            let userFilter = extractFlag(args: Array(args.dropFirst()), flag: "--user") ?? ""
            guard let resp = rpcCall(socketPath: socketPath, method: "context.event.list", params: [
                "limit": limit, "user_id": userFilter
            ] as [String: Any]),
                  let events = resp["events"] as? [[String: Any]] else {
                fputs("Error: could not list events\n", stderr)
                return 1
            }
            if events.isEmpty { print("No events yet"); return 0 }
            let fmt = DateFormatter()
            fmt.dateFormat = "MM-dd HH:mm"
            for e in events {
                let ts = (e["ts"] as? Int64) ?? Int64(e["ts"] as? Int ?? 0)
                let uid = e["user_id"] as? String ?? ""
                let action = e["action"] as? String ?? ""
                let kind = e["kind"] as? String ?? ""
                let target = e["target_id"] as? String ?? ""
                let summary = e["summary"] as? String ?? ""
                let date = fmt.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
                let who = uid.isEmpty ? "?" : String(uid.prefix(8))
                let tail = summary.isEmpty ? target : "\(target) — \(summary)"
                print("\(date)  \(who)  \(action) \(kind) \(tail)")
            }
            return 0
        case "locks":
            guard let resp = rpcCall(socketPath: socketPath, method: "context.lock.list", params: [:]),
                  let locks = resp["locks"] as? [[String: Any]] else {
                fputs("Error: could not list locks\n", stderr)
                return 1
            }
            if locks.isEmpty { print("No active locks"); return 0 }
            for l in locks {
                let kind = l["kind"] as? String ?? ""
                let target = l["target_id"] as? String ?? ""
                let name = l["user_name"] as? String ?? ""
                print("[\(kind)] \(target) — by \(name)")
            }
            return 0
        case "export":
            return handleExport(socketPath: socketPath)
        case "import":
            return handleImport(args: Array(args.dropFirst()), socketPath: socketPath)
        case "help", "--help", "-h":
            printUsage()
            return 0
        default:
            fputs("Unknown context command: \(args[0])\n", stderr)
            printUsage()
            return 2
        }
    }

    // MARK: - Show

    private static func handleShow(socketPath: String) -> Int32 {
        // KV summary
        if let resp = rpcCall(socketPath: socketPath, method: "context.kv.list", params: [:]),
           let entries = resp["entries"] as? [[String: Any]] {
            print("Key-Value Entries: \(entries.count)")
            for entry in entries.prefix(10) {
                let key = entry["key"] as? String ?? ""
                let value = entry["value"] as? String ?? ""
                let cat = entry["category"] as? String ?? ""
                let catLabel = cat.isEmpty ? "" : " [\(cat)]"
                print("  \(key)\(catLabel) = \(value)")
            }
            if entries.count > 10 {
                print("  ... and \(entries.count - 10) more")
            }
        }

        print()

        // Doc summary
        if let resp = rpcCall(socketPath: socketPath, method: "context.doc.list", params: ["limit": 10]),
           let docs = resp["documents"] as? [[String: Any]] {
            let count = resp["count"] as? Int ?? docs.count
            print("Documents: \(count)")
            for doc in docs {
                let title = doc["title"] as? String ?? ""
                let cat = doc["category"] as? String ?? ""
                let catLabel = cat.isEmpty ? "" : " [\(cat)]"
                print("  \(title)\(catLabel)")
            }
        }

        print()

        // Entity summary
        if let resp = rpcCall(socketPath: socketPath, method: "context.entity.list", params: [:]),
           let entities = resp["entities"] as? [[String: Any]] {
            print("Graph Entities: \(entities.count)")
            var typeCounts: [String: Int] = [:]
            for e in entities {
                let t = e["type"] as? String ?? "unknown"
                typeCounts[t, default: 0] += 1
            }
            for (type, count) in typeCounts.sorted(by: { $0.key < $1.key }) {
                print("  \(type): \(count)")
            }
        }

        return 0
    }

    // MARK: - KV operations

    private static func handleGet(key: String, socketPath: String) -> Int32 {
        guard let resp = rpcCall(socketPath: socketPath, method: "context.kv.get", params: ["key": key]) else {
            fputs("Error: could not connect to context daemon\n", stderr)
            return 1
        }
        if let value = resp["value"] as? String {
            print(value)
            return 0
        }
        fputs("Key not found: \(key)\n", stderr)
        return 1
    }

    private static func handleSet(key: String, value: String, category: String, author: String, socketPath: String) -> Int32 {
        guard let _ = rpcCall(socketPath: socketPath, method: "context.kv.set", params: [
            "key": key, "value": value, "category": category, "author": author
        ]) else {
            fputs("Error: could not set key\n", stderr)
            return 1
        }
        print("Set \(key) = \(value)")
        return 0
    }

    private static func handleDelete(key: String, author: String, socketPath: String) -> Int32 {
        guard let _ = rpcCall(socketPath: socketPath, method: "context.kv.delete", params: [
            "key": key, "author": author
        ]) else {
            fputs("Error: could not delete key\n", stderr)
            return 1
        }
        print("Deleted \(key)")
        return 0
    }

    // MARK: - Search

    private static func handleSearch(query: String, socketPath: String) -> Int32 {
        guard let resp = rpcCall(socketPath: socketPath, method: "context.search", params: ["query": query]) else {
            fputs("Error: search failed\n", stderr)
            return 1
        }
        guard let results = resp["results"] as? [[String: Any]], !results.isEmpty else {
            print("No results found for: \(query)")
            return 0
        }
        for result in results {
            let type = result["type"] as? String ?? ""
            let title = result["title"] as? String ?? ""
            let snippet = result["snippet"] as? String ?? ""
            print("[\(type)] \(title)")
            if !snippet.isEmpty {
                print("  \(snippet)")
            }
        }
        return 0
    }

    // MARK: - Documents

    private static func handleDoc(args: [String], socketPath: String) -> Int32 {
        guard !args.isEmpty else {
            fputs("Usage: cmux context doc <list|show|create|delete> [...]\n", stderr)
            return 2
        }

        switch args[0] {
        case "list":
            let category = extractFlag(args: Array(args.dropFirst()), flag: "--category")
            guard let resp = rpcCall(socketPath: socketPath, method: "context.doc.list", params: [
                "category": category ?? ""
            ]) else {
                fputs("Error: could not list documents\n", stderr)
                return 1
            }
            if let docs = resp["documents"] as? [[String: Any]] {
                if docs.isEmpty {
                    print("No documents")
                } else {
                    for doc in docs {
                        let id = doc["id"] as? String ?? ""
                        let title = doc["title"] as? String ?? ""
                        let cat = doc["category"] as? String ?? ""
                        let catLabel = cat.isEmpty ? "" : " [\(cat)]"
                        print("\(id)  \(title)\(catLabel)")
                    }
                }
            }
            return 0

        case "show":
            guard args.count >= 2 else {
                fputs("Usage: cmux context doc show <id>\n", stderr)
                return 2
            }
            guard let resp = rpcCall(socketPath: socketPath, method: "context.doc.get", params: ["id": args[1]]) else {
                fputs("Error: document not found\n", stderr)
                return 1
            }
            let title = resp["title"] as? String ?? ""
            let body = resp["body"] as? String ?? ""
            let cat = resp["category"] as? String ?? ""
            print("# \(title)")
            if !cat.isEmpty { print("Category: \(cat)") }
            print()
            print(body)
            return 0

        case "create":
            let title = extractFlag(args: Array(args.dropFirst()), flag: "-t") ?? extractFlag(args: Array(args.dropFirst()), flag: "--title")
            guard let title, !title.isEmpty else {
                fputs("Usage: cmux context doc create -t <title> [-f <file>] [-c <category>]\n", stderr)
                return 2
            }
            let filePath = extractFlag(args: Array(args.dropFirst()), flag: "-f")
            let category = extractFlag(args: Array(args.dropFirst()), flag: "-c") ?? ""
            var body = ""
            if let filePath {
                do {
                    body = try String(contentsOfFile: filePath, encoding: .utf8)
                } catch {
                    fputs("Error reading file: \(filePath)\n", stderr)
                    return 1
                }
            } else {
                // Read from stdin if available
                if isatty(fileno(stdin)) == 0 {
                    body = readLine(strippingNewline: false) ?? ""
                    while let line = readLine(strippingNewline: false) {
                        body += line
                    }
                }
            }
            let author = resolveAuthor(explicit: extractFlag(args: Array(args.dropFirst()), flag: "--author"))
            guard let resp = rpcCall(socketPath: socketPath, method: "context.doc.create", params: [
                "title": title, "body": body, "category": category, "author": author
            ]) else {
                fputs("Error: could not create document\n", stderr)
                return 1
            }
            let id = resp["id"] as? String ?? ""
            print("Created document: \(id) (\(title))")
            return 0

        case "delete":
            guard args.count >= 2 else {
                fputs("Usage: cmux context doc delete <id>\n", stderr)
                return 2
            }
            let author = resolveAuthor(explicit: extractFlag(args: Array(args.dropFirst(2)), flag: "--author"))
            guard let _ = rpcCall(socketPath: socketPath, method: "context.doc.delete", params: ["id": args[1], "author": author]) else {
                fputs("Error: could not delete document\n", stderr)
                return 1
            }
            print("Deleted document: \(args[1])")
            return 0

        default:
            fputs("Unknown doc command: \(args[0])\n", stderr)
            return 2
        }
    }

    // MARK: - Entities

    private static func handleEntity(args: [String], socketPath: String) -> Int32 {
        guard !args.isEmpty else {
            fputs("Usage: cmux context entity <list|show|create|delete> [...]\n", stderr)
            return 2
        }

        switch args[0] {
        case "list":
            let type = extractFlag(args: Array(args.dropFirst()), flag: "--type")
            guard let resp = rpcCall(socketPath: socketPath, method: "context.entity.list", params: [
                "type": type ?? ""
            ]) else {
                fputs("Error: could not list entities\n", stderr)
                return 1
            }
            if let entities = resp["entities"] as? [[String: Any]] {
                if entities.isEmpty {
                    print("No entities")
                } else {
                    for e in entities {
                        let id = e["id"] as? String ?? ""
                        let name = e["name"] as? String ?? ""
                        let type = e["type"] as? String ?? ""
                        print("\(id)  [\(type)] \(name)")
                    }
                }
            }
            return 0

        case "show":
            guard args.count >= 2 else {
                fputs("Usage: cmux context entity show <id>\n", stderr)
                return 2
            }
            guard let resp = rpcCall(socketPath: socketPath, method: "context.entity.get", params: ["id": args[1]]) else {
                fputs("Error: entity not found\n", stderr)
                return 1
            }
            let name = resp["name"] as? String ?? ""
            let type = resp["type"] as? String ?? ""
            print("[\(type)] \(name)")
            if let props = resp["properties"] as? [String: Any], !props.isEmpty {
                print("Properties:")
                for (k, v) in props.sorted(by: { $0.key < $1.key }) {
                    print("  \(k): \(v)")
                }
            }
            // Show edges
            if let edgeResp = rpcCall(socketPath: socketPath, method: "context.edge.list", params: ["entity_id": args[1]]),
               let edges = edgeResp["edges"] as? [[String: Any]], !edges.isEmpty {
                print("Connections:")
                for edge in edges {
                    let relation = edge["relation"] as? String ?? ""
                    let sourceId = edge["source_id"] as? String ?? ""
                    let targetId = edge["target_id"] as? String ?? ""
                    if sourceId == args[1] {
                        print("  → \(relation) → \(targetId)")
                    } else {
                        print("  ← \(relation) ← \(sourceId)")
                    }
                }
            }
            return 0

        case "create":
            let type = extractFlag(args: Array(args.dropFirst()), flag: "--type") ?? "service"
            let name = extractFlag(args: Array(args.dropFirst()), flag: "--name")
            guard let name, !name.isEmpty else {
                fputs("Usage: cmux context entity create --type <type> --name <name>\n", stderr)
                return 2
            }
            let author = resolveAuthor(explicit: extractFlag(args: Array(args.dropFirst()), flag: "--author"))
            guard let resp = rpcCall(socketPath: socketPath, method: "context.entity.create", params: [
                "type": type, "name": name, "author": author
            ]) else {
                fputs("Error: could not create entity\n", stderr)
                return 1
            }
            let id = resp["id"] as? String ?? ""
            print("Created entity: \(id) [\(type)] \(name)")
            return 0

        case "delete":
            guard args.count >= 2 else {
                fputs("Usage: cmux context entity delete <id>\n", stderr)
                return 2
            }
            let author = resolveAuthor(explicit: extractFlag(args: Array(args.dropFirst(2)), flag: "--author"))
            guard let _ = rpcCall(socketPath: socketPath, method: "context.entity.delete", params: ["id": args[1], "author": author]) else {
                fputs("Error: could not delete entity\n", stderr)
                return 1
            }
            print("Deleted entity: \(args[1])")
            return 0

        default:
            fputs("Unknown entity command: \(args[0])\n", stderr)
            return 2
        }
    }

    // MARK: - Export / Import

    private static func handleExport(socketPath: String) -> Int32 {
        guard let data = rpcCallRaw(socketPath: socketPath, method: "context.export", params: [:]) else {
            fputs("Error: export failed\n", stderr)
            return 1
        }
        // Extract the result field from the response
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let result = json["result"],
           let resultData = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            print(String(data: resultData, encoding: .utf8) ?? "")
        }
        return 0
    }

    private static func handleImport(args: [String], socketPath: String) -> Int32 {
        var jsonData: Data
        if let filePath = args.first, !filePath.starts(with: "-") {
            do {
                jsonData = try Data(contentsOf: URL(fileURLWithPath: filePath))
            } catch {
                fputs("Error reading file: \(filePath)\n", stderr)
                return 1
            }
        } else if isatty(fileno(stdin)) == 0 {
            jsonData = FileHandle.standardInput.readDataToEndOfFile()
        } else {
            fputs("Usage: cmux context import <file> or pipe JSON to stdin\n", stderr)
            return 2
        }

        guard let importData = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            fputs("Error: invalid JSON\n", stderr)
            return 1
        }

        guard let resp = rpcCall(socketPath: socketPath, method: "context.import", params: ["data": importData]) else {
            fputs("Error: import failed\n", stderr)
            return 1
        }

        if let imported = resp["imported"] as? [String: Any] {
            print("Imported:")
            for (key, value) in imported.sorted(by: { $0.key < $1.key }) {
                print("  \(key): \(value)")
            }
        }
        return 0
    }

    // MARK: - Socket communication

    private static func rpcCall(socketPath: String, method: String, params: [String: Any]) -> [String: Any]? {
        guard let data = rpcCallRaw(socketPath: socketPath, method: method, params: params) else {
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard json["ok"] as? Bool == true else {
            if let error = json["error"] as? [String: Any], let msg = error["message"] as? String {
                fputs("Error: \(msg)\n", stderr)
            }
            return nil
        }
        return json["result"] as? [String: Any]
    }

    private static func rpcCallRaw(socketPath: String, method: String, params: [String: Any]) -> Data? {
        if let remote = resolveRemoteConfig() {
            return rpcCallTCP(host: remote.host, port: remote.port, token: remote.token, method: method, params: params)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for (i, byte) in pathBytes.enumerated() {
                    dest[i] = byte
                }
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { return nil }

        return sendAndReceive(fd: fd, method: method, params: params)
    }

    private static func sendAndReceive(fd: Int32, method: String, params: [String: Any]) -> Data? {
        let request: [String: Any] = ["id": 1, "method": method, "params": params]
        guard let requestData = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        var line = requestData
        line.append(contentsOf: [UInt8(ascii: "\n")])

        let sent = line.withUnsafeBytes { ptr in
            send(fd, ptr.baseAddress, ptr.count, 0)
        }
        guard sent == line.count else { return nil }

        var responseData = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            responseData.append(contentsOf: buf[0..<n])
            if buf[0..<n].contains(UInt8(ascii: "\n")) { break }
        }
        return responseData.isEmpty ? nil : responseData
    }

    private struct RemoteCfg { let host: String; let port: Int; let token: String }

    /// Reads .cmux_team/connection.json in the current project. Returns nil if local or missing.
    private static func resolveRemoteConfig() -> RemoteCfg? {
        let cwd = ProcessInfo.processInfo.environment["CMUX_PROJECT_ROOT"]
            ?? FileManager.default.currentDirectoryPath
        let url = URL(fileURLWithPath: cwd)
            .appendingPathComponent(".cmux_team")
            .appendingPathComponent("connection.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["mode"] as? String) == "remote",
              let host = json["host"] as? String, !host.isEmpty,
              let port = json["port"] as? Int,
              let token = json["token"] as? String, !token.isEmpty
        else { return nil }
        return RemoteCfg(host: host, port: port, token: token)
    }

    private static func rpcCallTCP(host: String, port: Int, token: String, method: String, params: [String: Any]) -> Data? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        if inet_pton(AF_INET, host, &addr.sin_addr) != 1 {
            // Try DNS resolve via getaddrinfo
            var hints = addrinfo()
            hints.ai_family = AF_INET
            hints.ai_socktype = SOCK_STREAM
            var res: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, String(port), &hints, &res) == 0, let first = res else { return nil }
            defer { freeaddrinfo(first) }
            if let sa = first.pointee.ai_addr {
                sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { p in
                    addr.sin_addr = p.pointee.sin_addr
                }
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                connect(fd, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else { return nil }

        // Authenticate
        let authReq: [String: Any] = ["id": 0, "method": "auth", "params": ["token": token]]
        guard let authData = try? JSONSerialization.data(withJSONObject: authReq) else { return nil }
        var authLine = authData
        authLine.append(UInt8(ascii: "\n"))
        let authSent = authLine.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        guard authSent == authLine.count else { return nil }
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = recv(fd, &buf, buf.count, 0)
        guard n > 0 else { return nil }
        if let resp = try? JSONSerialization.jsonObject(with: Data(buf[0..<n])) as? [String: Any],
           resp["ok"] as? Bool != true {
            fputs("auth failed\n", stderr)
            return nil
        }

        return sendAndReceive(fd: fd, method: method, params: params)
    }

    // MARK: - Helpers

    /// Resolves the current author id by checking, in order:
    /// 1. `--author <id>` flag in argv (removed by caller via extractFlag usage)
    /// 2. `CMUX_CONTEXT_AUTHOR` env var
    /// 3. `$PWD/.cmux_team/me.json` → `user_id` field
    private static func resolveAuthor(explicit: String? = nil) -> String {
        if let explicit, !explicit.isEmpty { return explicit }
        if let env = ProcessInfo.processInfo.environment["CMUX_CONTEXT_AUTHOR"], !env.isEmpty { return env }
        let cwd = ProcessInfo.processInfo.environment["CMUX_PROJECT_ROOT"]
            ?? FileManager.default.currentDirectoryPath
        let url = URL(fileURLWithPath: cwd)
            .appendingPathComponent(".cmux_team")
            .appendingPathComponent("me.json")
        if let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let uid = json["user_id"] as? String {
            return uid
        }
        return ""
    }

    private static func resolveSocketPath() -> String {
        if let env = ProcessInfo.processInfo.environment["CMUX_CONTEXT_SOCKET_PATH"] {
            return env
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.config/cmux/context.sock"
    }

    private static func extractFlag(args: [String], flag: String) -> String? {
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }

    private static func printUsage() {
        let usage = """
        Usage: cmux context <command> [args...]

        Commands:
          show                              Show context summary
          get <key>                         Get a key-value entry
          set <key> <value> [-c category]   Set a key-value entry
          delete <key>                      Delete a key-value entry
          search <query>                    Search across all context

          doc list [--category <cat>]       List documents
          doc show <id>                     Show document content
          doc create -t <title> [-f <file>] [-c <category>]
                                            Create a document
          doc delete <id>                   Delete a document

          entity list [--type <type>]       List graph entities
          entity show <id>                  Show entity with connections
          entity create --type <t> --name <n>  Create entity
          entity delete <id>                Delete entity

          whoami                            Show the current identity (from .cmux_team/me.json)
          users                             List all users
          events [-n 20] [--user <id>]      Recent activity log (who changed what)
          locks                             List active edit locks

          export                            Export all context as JSON
          import <file>                     Import context from JSON

        Attribution:
          Mutations accept --author <id>. If omitted, CMUX_CONTEXT_AUTHOR env var
          or .cmux_team/me.json (user_id field) is used.
        """
        print(usage)
    }

    // Silence unused import warning
    private static let _isatty = isatty
}

// isatty is imported from Darwin/Glibc
#if canImport(Darwin)
import Darwin
#endif
