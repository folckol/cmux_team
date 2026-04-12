package main

import (
	"bufio"
	"database/sql"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"

	_ "modernc.org/sqlite"
)

var version = "dev"

type rpcRequest struct {
	ID     any            `json:"id"`
	Method string         `json:"method"`
	Params map[string]any `json:"params"`
}

type rpcError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type rpcResponse struct {
	ID     any       `json:"id,omitempty"`
	OK     bool      `json:"ok"`
	Result any       `json:"result,omitempty"`
	Error  *rpcError `json:"error,omitempty"`
}

type contextServer struct {
	store     *Store
	locks     *LockManager
	authToken string // empty = no auth required (Unix socket), non-empty = required (TCP)
}

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(args []string) int {
	fs := flag.NewFlagSet("cmuxd-context", flag.ContinueOnError)
	socketPath := fs.String("socket", defaultSocketPath(), "Unix socket path")
	dbPath := fs.String("db", defaultDBPath(), "SQLite database path")
	tcpAddr := fs.String("tcp", "", "TCP listen address (e.g. 0.0.0.0:9876) for remote access")
	authToken := fs.String("token", "", "Authentication token for TCP connections")
	showVersion := fs.Bool("version", false, "Print version and exit")

	if err := fs.Parse(args); err != nil {
		return 2
	}

	if *showVersion {
		fmt.Println(version)
		return 0
	}

	// Ensure directories exist
	if err := os.MkdirAll(filepath.Dir(*dbPath), 0700); err != nil {
		fmt.Fprintf(os.Stderr, "create db dir: %v\n", err)
		return 1
	}
	if err := os.MkdirAll(filepath.Dir(*socketPath), 0700); err != nil {
		fmt.Fprintf(os.Stderr, "create socket dir: %v\n", err)
		return 1
	}

	// Remove stale socket
	if _, err := os.Stat(*socketPath); err == nil {
		// Check if another process is listening
		conn, err := net.Dial("unix", *socketPath)
		if err == nil {
			conn.Close()
			fmt.Fprintf(os.Stderr, "another cmuxd-context is already running on %s\n", *socketPath)
			return 1
		}
		os.Remove(*socketPath)
	}

	// Open database
	db, err := sql.Open("sqlite", *dbPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "open db: %v\n", err)
		return 1
	}
	defer db.Close()

	// Single writer, allow concurrent reads
	db.SetMaxOpenConns(1)

	if err := initSchema(db); err != nil {
		fmt.Fprintf(os.Stderr, "init schema: %v\n", err)
		return 1
	}

	store := NewStore(db)
	server := &contextServer{store: store, locks: NewLockManager(), authToken: *authToken}

	// Listen on Unix socket
	listener, err := net.Listen("unix", *socketPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "listen: %v\n", err)
		return 1
	}
	defer listener.Close()

	if err := os.Chmod(*socketPath, 0600); err != nil {
		fmt.Fprintf(os.Stderr, "chmod socket: %v\n", err)
	}

	fmt.Fprintf(os.Stderr, "cmuxd-context %s listening on %s (db: %s)\n", version, *socketPath, *dbPath)

	// Optional TCP listener for remote access
	var tcpListener net.Listener
	if *tcpAddr != "" {
		if *authToken == "" {
			fmt.Fprintf(os.Stderr, "error: -token is required when using -tcp\n")
			return 1
		}
		var tcpErr error
		tcpListener, tcpErr = net.Listen("tcp", *tcpAddr)
		if tcpErr != nil {
			fmt.Fprintf(os.Stderr, "tcp listen: %v\n", tcpErr)
			return 1
		}
		defer tcpListener.Close()
		fmt.Fprintf(os.Stderr, "TCP listener on %s (token-auth required)\n", *tcpAddr)
	}

	// Graceful shutdown
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	var wg sync.WaitGroup
	go func() {
		<-sigCh
		fmt.Fprintf(os.Stderr, "shutting down...\n")
		listener.Close()
		if tcpListener != nil {
			tcpListener.Close()
		}
	}()

	// Accept TCP connections in background
	if tcpListener != nil {
		go func() {
			for {
				conn, err := tcpListener.Accept()
				if err != nil {
					if errors.Is(err, net.ErrClosed) {
						return
					}
					fmt.Fprintf(os.Stderr, "tcp accept: %v\n", err)
					continue
				}
				wg.Add(1)
				go func() {
					defer wg.Done()
					server.handleConnection(conn)
				}()
			}
		}()
	}

	// Accept Unix socket connections
	for {
		conn, err := listener.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				break
			}
			fmt.Fprintf(os.Stderr, "accept: %v\n", err)
			continue
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			server.handleConnection(conn)
		}()
	}

	wg.Wait()
	return 0
}

func (s *contextServer) handleConnection(conn net.Conn) {
	defer conn.Close()
	reader := bufio.NewReader(conn)
	writer := bufio.NewWriter(conn)

	// Determine if auth is needed (TCP connections require token)
	_, isTCP := conn.(*net.TCPConn)
	authenticated := !isTCP || s.authToken == ""

	for {
		line, err := reader.ReadBytes('\n')
		if err != nil {
			if !errors.Is(err, io.EOF) {
				fmt.Fprintf(os.Stderr, "read: %v\n", err)
			}
			return
		}

		line = trimCRLF(line)
		if len(line) == 0 {
			continue
		}

		var req rpcRequest
		if err := json.Unmarshal(line, &req); err != nil {
			writeResponse(writer, rpcResponse{OK: false, Error: &rpcError{Code: "invalid_request", Message: "invalid JSON"}})
			continue
		}

		// Auth check: first request from TCP must be "auth"
		if !authenticated {
			if req.Method == "auth" {
				token, _ := req.Params["token"].(string)
				if token == s.authToken {
					authenticated = true
					writeResponse(writer, okResponse(req.ID, map[string]any{"authenticated": true}))
				} else {
					writeResponse(writer, errResponse(req.ID, "auth_failed", "invalid token"))
					return // Disconnect on bad auth
				}
				continue
			}
			writeResponse(writer, errResponse(req.ID, "auth_required", "send auth request first with token"))
			continue
		}

		resp := s.dispatch(req)
		writeResponse(writer, resp)
	}
}

func (s *contextServer) dispatch(req rpcRequest) rpcResponse {
	if req.Method == "" {
		return errResponse(req.ID, "invalid_request", "method is required")
	}

	switch req.Method {
	// Utility
	case "hello":
		return okResponse(req.ID, map[string]any{
			"name":    "cmuxd-context",
			"version": version,
		})
	case "ping":
		return okResponse(req.ID, map[string]any{"pong": true})

	// KV
	case "context.kv.get":
		return s.handleKVGet(req)
	case "context.kv.set":
		return s.handleKVSet(req)
	case "context.kv.delete":
		return s.handleKVDelete(req)
	case "context.kv.list":
		return s.handleKVList(req)

	// Documents
	case "context.doc.get":
		return s.handleDocGet(req)
	case "context.doc.create":
		return s.handleDocCreate(req)
	case "context.doc.update":
		return s.handleDocUpdate(req)
	case "context.doc.delete":
		return s.handleDocDelete(req)
	case "context.doc.list":
		return s.handleDocList(req)
	case "context.doc.search":
		return s.handleDocSearch(req)

	// Entities
	case "context.entity.create":
		return s.handleEntityCreate(req)
	case "context.entity.get":
		return s.handleEntityGet(req)
	case "context.entity.update":
		return s.handleEntityUpdate(req)
	case "context.entity.delete":
		return s.handleEntityDelete(req)
	case "context.entity.list":
		return s.handleEntityList(req)

	// Edges
	case "context.edge.create":
		return s.handleEdgeCreate(req)
	case "context.edge.delete":
		return s.handleEdgeDelete(req)
	case "context.edge.list":
		return s.handleEdgeList(req)

	// Search & Export/Import
	case "context.search":
		return s.handleSearch(req)
	case "context.export":
		return s.handleExport(req)
	case "context.import":
		return s.handleImport(req)

	// Users
	case "context.user.create":
		return s.handleUserCreate(req)
	case "context.user.list":
		return s.handleUserList(req)
	case "context.user.get":
		return s.handleUserGet(req)
	case "context.user.delete":
		return s.handleUserDelete(req)

	// Locks
	case "context.lock.acquire":
		return s.handleLockAcquire(req)
	case "context.lock.heartbeat":
		return s.handleLockHeartbeat(req)
	case "context.lock.release":
		return s.handleLockRelease(req)
	case "context.lock.list":
		return s.handleLockList(req)

	// Events
	case "context.event.list":
		return s.handleEventList(req)

	default:
		return errResponse(req.ID, "method_not_found", "unknown method: "+req.Method)
	}
}

// --- Users handlers ---

func (s *contextServer) handleUserCreate(req rpcRequest) rpcResponse {
	id, _ := req.Params["id"].(string)
	name, _ := req.Params["name"].(string)
	role, _ := req.Params["role"].(string)
	email, _ := req.Params["email"].(string)
	if name == "" {
		return errResponse(req.ID, "invalid_params", "name is required")
	}
	u, err := s.store.UserCreate(id, name, role, email)
	if err != nil {
		return errResponse(req.ID, "internal", err.Error())
	}
	return okResponse(req.ID, u)
}

func (s *contextServer) handleUserList(req rpcRequest) rpcResponse {
	users, err := s.store.UserList()
	if err != nil {
		return errResponse(req.ID, "internal", err.Error())
	}
	if users == nil {
		users = []User{}
	}
	return okResponse(req.ID, map[string]any{"users": users, "count": len(users)})
}

func (s *contextServer) handleUserGet(req rpcRequest) rpcResponse {
	id, _ := req.Params["id"].(string)
	if id == "" {
		return errResponse(req.ID, "invalid_params", "id is required")
	}
	u, err := s.store.UserGet(id)
	if err != nil {
		return errResponse(req.ID, "internal", err.Error())
	}
	if u == nil {
		return errResponse(req.ID, "not_found", "user not found")
	}
	return okResponse(req.ID, u)
}

func (s *contextServer) handleUserDelete(req rpcRequest) rpcResponse {
	id, _ := req.Params["id"].(string)
	if err := s.store.UserDelete(id); err != nil {
		return errResponse(req.ID, "not_found", err.Error())
	}
	return okResponse(req.ID, map[string]any{"deleted": true})
}

// --- Locks handlers ---

func (s *contextServer) handleLockAcquire(req rpcRequest) rpcResponse {
	kind, _ := req.Params["kind"].(string)
	id, _ := req.Params["target_id"].(string)
	userID, _ := req.Params["user_id"].(string)
	userName, _ := req.Params["user_name"].(string)
	if kind == "" || id == "" || userID == "" {
		return errResponse(req.ID, "invalid_params", "kind, target_id, user_id required")
	}
	ok, holderID, holderName := s.locks.Acquire(kind, id, userID, userName)
	if !ok {
		return rpcResponse{ID: req.ID, OK: false, Error: lockConflictError(kind, id, holderID, holderName)}
	}
	return okResponse(req.ID, map[string]any{"locked": true, "holder_id": holderID, "holder_name": holderName})
}

func (s *contextServer) handleLockHeartbeat(req rpcRequest) rpcResponse {
	kind, _ := req.Params["kind"].(string)
	id, _ := req.Params["target_id"].(string)
	userID, _ := req.Params["user_id"].(string)
	ok := s.locks.Heartbeat(kind, id, userID)
	return okResponse(req.ID, map[string]any{"held": ok})
}

func (s *contextServer) handleLockRelease(req rpcRequest) rpcResponse {
	kind, _ := req.Params["kind"].(string)
	id, _ := req.Params["target_id"].(string)
	userID, _ := req.Params["user_id"].(string)
	s.locks.Release(kind, id, userID)
	return okResponse(req.ID, map[string]any{"released": true})
}

func (s *contextServer) handleLockList(req rpcRequest) rpcResponse {
	items := s.locks.List()
	if items == nil {
		items = []LockInfo{}
	}
	return okResponse(req.ID, map[string]any{"locks": items, "count": len(items)})
}

// --- Events handler ---

func (s *contextServer) handleEventList(req rpcRequest) rpcResponse {
	limit := intParam(req.Params, "limit", 50)
	userID, _ := req.Params["user_id"].(string)
	events, err := s.store.EventList(limit, userID)
	if err != nil {
		return errResponse(req.ID, "internal", err.Error())
	}
	if events == nil {
		events = []Event{}
	}
	return okResponse(req.ID, map[string]any{"events": events, "count": len(events)})
}

// --- KV handlers ---

func (s *contextServer) handleKVGet(req rpcRequest) rpcResponse {
	key, _ := req.Params["key"].(string)
	if key == "" {
		return errResponse(req.ID, "invalid_params", "key is required")
	}
	entry, err := s.store.KVGet(key)
	if err != nil {
		return errResponse(req.ID, "internal", err.Error())
	}
	if entry == nil {
		return errResponse(req.ID, "not_found", "key not found: "+key)
	}
	return okResponse(req.ID, entry)
}

func (s *contextServer) handleKVSet(req rpcRequest) rpcResponse {
	key, _ := req.Params["key"].(string)
	value, _ := req.Params["value"].(string)
	category, _ := req.Params["category"].(string)
	author := authorParam(req.Params)
	tags := parseStringSlice(req.Params["tags"])
	if key == "" {
		return errResponse(req.ID, "invalid_params", "key is required")
	}
	if ok, hID, hName := s.locks.CheckWrite("kv", key, author); !ok {
		return rpcResponse{ID: req.ID, OK: false, Error: lockConflictError("kv", key, hID, hName)}
	}
	entry, err := s.store.KVSet(key, value, category, tags, author)
	if err != nil {
		return errResponse(req.ID, "internal", err.Error())
	}
	s.store.LogEvent(author, "set", "kv", key, value)
	return okResponse(req.ID, entry)
}

func (s *contextServer) handleKVDelete(req rpcRequest) rpcResponse {
	key, _ := req.Params["key"].(string)
	author := authorParam(req.Params)
	if key == "" {
		return errResponse(req.ID, "invalid_params", "key is required")
	}
	if ok, hID, hName := s.locks.CheckWrite("kv", key, author); !ok {
		return rpcResponse{ID: req.ID, OK: false, Error: lockConflictError("kv", key, hID, hName)}
	}
	if err := s.store.KVDelete(key); err != nil {
		return errResponse(req.ID, "not_found", err.Error())
	}
	s.store.LogEvent(author, "delete", "kv", key, "")
	return okResponse(req.ID, map[string]any{"deleted": true})
}

func (s *contextServer) handleKVList(req rpcRequest) rpcResponse {
	category, _ := req.Params["category"].(string)
	prefix, _ := req.Params["prefix"].(string)
	entries, err := s.store.KVList(category, prefix)
	if err != nil {
		return errResponse(req.ID, "internal", err.Error())
	}
	if entries == nil {
		entries = []KVEntry{}
	}
	return okResponse(req.ID, map[string]any{"entries": entries, "count": len(entries)})
}

// --- Document handlers ---

func (s *contextServer) handleDocGet(req rpcRequest) rpcResponse {
	id, _ := req.Params["id"].(string)
	if id == "" {
		return errResponse(req.ID, "invalid_params", "id is required")
	}
	doc, err := s.store.DocGet(id)
	if err != nil {
		return errResponse(req.ID, "internal", err.Error())
	}
	if doc == nil {
		return errResponse(req.ID, "not_found", "document not found: "+id)
	}
	return okResponse(req.ID, doc)
}

func (s *contextServer) handleDocCreate(req rpcRequest) rpcResponse {
	title, _ := req.Params["title"].(string)
	body, _ := req.Params["body"].(string)
	category, _ := req.Params["category"].(string)
	author := authorParam(req.Params)
	tags := parseStringSlice(req.Params["tags"])
	if title == "" {
		return errResponse(req.ID, "invalid_params", "title is required")
	}
	doc, err := s.store.DocCreate(title, body, category, tags, author)
	if err != nil {
		return errResponse(req.ID, "internal", err.Error())
	}
	s.store.LogEvent(author, "create", "doc", doc.ID, title)
	return okResponse(req.ID, doc)
}

func (s *contextServer) handleDocUpdate(req rpcRequest) rpcResponse {
	id, _ := req.Params["id"].(string)
	author := authorParam(req.Params)
	if id == "" {
		return errResponse(req.ID, "invalid_params", "id is required")
	}
	if ok, hID, hName := s.locks.CheckWrite("doc", id, author); !ok {
		return rpcResponse{ID: req.ID, OK: false, Error: lockConflictError("doc", id, hID, hName)}
	}
	var title, body, category *string
	if v, ok := req.Params["title"].(string); ok {
		title = &v
	}
	if v, ok := req.Params["body"].(string); ok {
		body = &v
	}
	if v, ok := req.Params["category"].(string); ok {
		category = &v
	}
	var tags []string
	if _, ok := req.Params["tags"]; ok {
		tags = parseStringSlice(req.Params["tags"])
	}
	doc, err := s.store.DocUpdate(id, title, body, tags, category, author)
	if err != nil {
		return errResponse(req.ID, "not_found", err.Error())
	}
	s.store.LogEvent(author, "update", "doc", doc.ID, doc.Title)
	return okResponse(req.ID, doc)
}

func (s *contextServer) handleDocDelete(req rpcRequest) rpcResponse {
	id, _ := req.Params["id"].(string)
	author := authorParam(req.Params)
	if id == "" {
		return errResponse(req.ID, "invalid_params", "id is required")
	}
	if ok, hID, hName := s.locks.CheckWrite("doc", id, author); !ok {
		return rpcResponse{ID: req.ID, OK: false, Error: lockConflictError("doc", id, hID, hName)}
	}
	if err := s.store.DocDelete(id); err != nil {
		return errResponse(req.ID, "not_found", err.Error())
	}
	s.store.LogEvent(author, "delete", "doc", id, "")
	return okResponse(req.ID, map[string]any{"deleted": true})
}

func (s *contextServer) handleDocList(req rpcRequest) rpcResponse {
	category, _ := req.Params["category"].(string)
	tag, _ := req.Params["tag"].(string)
	limit := intParam(req.Params, "limit", 50)
	offset := intParam(req.Params, "offset", 0)
	docs, err := s.store.DocList(category, tag, limit, offset)
	if err != nil {
		return errResponse(req.ID, "internal", err.Error())
	}
	if docs == nil {
		docs = []Document{}
	}
	return okResponse(req.ID, map[string]any{"documents": docs, "count": len(docs)})
}

func (s *contextServer) handleDocSearch(req rpcRequest) rpcResponse {
	query, _ := req.Params["query"].(string)
	if query == "" {
		return errResponse(req.ID, "invalid_params", "query is required")
	}
	docs, err := s.store.DocSearch(query)
	if err != nil {
		return errResponse(req.ID, "internal", err.Error())
	}
	if docs == nil {
		docs = []Document{}
	}
	return okResponse(req.ID, map[string]any{"documents": docs, "count": len(docs)})
}

// --- Entity handlers ---

func (s *contextServer) handleEntityCreate(req rpcRequest) rpcResponse {
	entityType, _ := req.Params["type"].(string)
	name, _ := req.Params["name"].(string)
	properties, _ := req.Params["properties"].(map[string]any)
	author := authorParam(req.Params)
	if entityType == "" || name == "" {
		return errResponse(req.ID, "invalid_params", "type and name are required")
	}
	entity, err := s.store.EntityCreate(entityType, name, properties, author)
	if err != nil {
		return errResponse(req.ID, "internal", err.Error())
	}
	s.store.LogEvent(author, "create", "entity", entity.ID, entityType+":"+name)
	return okResponse(req.ID, entity)
}

func (s *contextServer) handleEntityGet(req rpcRequest) rpcResponse {
	id, _ := req.Params["id"].(string)
	if id == "" {
		return errResponse(req.ID, "invalid_params", "id is required")
	}
	entity, err := s.store.EntityGet(id)
	if err != nil {
		return errResponse(req.ID, "internal", err.Error())
	}
	if entity == nil {
		return errResponse(req.ID, "not_found", "entity not found: "+id)
	}
	return okResponse(req.ID, entity)
}

func (s *contextServer) handleEntityUpdate(req rpcRequest) rpcResponse {
	id, _ := req.Params["id"].(string)
	author := authorParam(req.Params)
	if id == "" {
		return errResponse(req.ID, "invalid_params", "id is required")
	}
	if ok, hID, hName := s.locks.CheckWrite("entity", id, author); !ok {
		return rpcResponse{ID: req.ID, OK: false, Error: lockConflictError("entity", id, hID, hName)}
	}
	var name *string
	if v, ok := req.Params["name"].(string); ok {
		name = &v
	}
	properties, _ := req.Params["properties"].(map[string]any)
	entity, err := s.store.EntityUpdate(id, name, properties, author)
	if err != nil {
		return errResponse(req.ID, "not_found", err.Error())
	}
	s.store.LogEvent(author, "update", "entity", entity.ID, entity.Name)
	return okResponse(req.ID, entity)
}

func (s *contextServer) handleEntityDelete(req rpcRequest) rpcResponse {
	id, _ := req.Params["id"].(string)
	author := authorParam(req.Params)
	if id == "" {
		return errResponse(req.ID, "invalid_params", "id is required")
	}
	if ok, hID, hName := s.locks.CheckWrite("entity", id, author); !ok {
		return rpcResponse{ID: req.ID, OK: false, Error: lockConflictError("entity", id, hID, hName)}
	}
	if err := s.store.EntityDelete(id); err != nil {
		return errResponse(req.ID, "not_found", err.Error())
	}
	s.store.LogEvent(author, "delete", "entity", id, "")
	return okResponse(req.ID, map[string]any{"deleted": true})
}

func (s *contextServer) handleEntityList(req rpcRequest) rpcResponse {
	entityType, _ := req.Params["type"].(string)
	limit := intParam(req.Params, "limit", 100)
	entities, err := s.store.EntityList(entityType, limit)
	if err != nil {
		return errResponse(req.ID, "internal", err.Error())
	}
	if entities == nil {
		entities = []Entity{}
	}
	return okResponse(req.ID, map[string]any{"entities": entities, "count": len(entities)})
}

// --- Edge handlers ---

func (s *contextServer) handleEdgeCreate(req rpcRequest) rpcResponse {
	sourceID, _ := req.Params["source_id"].(string)
	targetID, _ := req.Params["target_id"].(string)
	relation, _ := req.Params["relation"].(string)
	properties, _ := req.Params["properties"].(map[string]any)
	author := authorParam(req.Params)
	if sourceID == "" || targetID == "" || relation == "" {
		return errResponse(req.ID, "invalid_params", "source_id, target_id, and relation are required")
	}
	edge, err := s.store.EdgeCreate(sourceID, targetID, relation, properties, author)
	if err != nil {
		return errResponse(req.ID, "internal", err.Error())
	}
	s.store.LogEvent(author, "create", "edge", edge.ID, relation)
	return okResponse(req.ID, edge)
}

func (s *contextServer) handleEdgeDelete(req rpcRequest) rpcResponse {
	id, _ := req.Params["id"].(string)
	author := authorParam(req.Params)
	if id == "" {
		return errResponse(req.ID, "invalid_params", "id is required")
	}
	if err := s.store.EdgeDelete(id); err != nil {
		return errResponse(req.ID, "not_found", err.Error())
	}
	s.store.LogEvent(author, "delete", "edge", id, "")
	return okResponse(req.ID, map[string]any{"deleted": true})
}

func (s *contextServer) handleEdgeList(req rpcRequest) rpcResponse {
	entityID, _ := req.Params["entity_id"].(string)
	relation, _ := req.Params["relation"].(string)
	direction, _ := req.Params["direction"].(string)
	edges, err := s.store.EdgeList(entityID, relation, direction)
	if err != nil {
		return errResponse(req.ID, "internal", err.Error())
	}
	if edges == nil {
		edges = []Edge{}
	}
	return okResponse(req.ID, map[string]any{"edges": edges, "count": len(edges)})
}

// --- Search & Export/Import handlers ---

func (s *contextServer) handleSearch(req rpcRequest) rpcResponse {
	query, _ := req.Params["query"].(string)
	if query == "" {
		return errResponse(req.ID, "invalid_params", "query is required")
	}
	results, err := s.store.UnifiedSearch(query)
	if err != nil {
		return errResponse(req.ID, "internal", err.Error())
	}
	if results == nil {
		results = []SearchResult{}
	}
	return okResponse(req.ID, map[string]any{"results": results, "count": len(results)})
}

func (s *contextServer) handleExport(req rpcRequest) rpcResponse {
	data, err := s.store.Export()
	if err != nil {
		return errResponse(req.ID, "internal", err.Error())
	}
	return okResponse(req.ID, data)
}

func (s *contextServer) handleImport(req rpcRequest) rpcResponse {
	data, _ := req.Params["data"].(map[string]any)
	if data == nil {
		return errResponse(req.ID, "invalid_params", "data object is required")
	}
	counts, err := s.store.Import(data)
	if err != nil {
		return errResponse(req.ID, "internal", err.Error())
	}
	return okResponse(req.ID, map[string]any{"imported": counts})
}

// --- Helpers ---

func okResponse(id any, result any) rpcResponse {
	return rpcResponse{ID: id, OK: true, Result: result}
}

func errResponse(id any, code, message string) rpcResponse {
	return rpcResponse{ID: id, OK: false, Error: &rpcError{Code: code, Message: message}}
}

func writeResponse(w *bufio.Writer, resp rpcResponse) {
	data, err := json.Marshal(resp)
	if err != nil {
		return
	}
	w.Write(data)
	w.WriteByte('\n')
	w.Flush()
}

func trimCRLF(b []byte) []byte {
	b = removeSuffix(b, '\n')
	b = removeSuffix(b, '\r')
	return b
}

func removeSuffix(b []byte, c byte) []byte {
	if len(b) > 0 && b[len(b)-1] == c {
		return b[:len(b)-1]
	}
	return b
}

// authorParam extracts the author user id from RPC params.
// Accepts "author" (new) or "created_by" (legacy) for backward compat.
func authorParam(params map[string]any) string {
	if v, ok := params["author"].(string); ok && v != "" {
		return v
	}
	if v, ok := params["created_by"].(string); ok {
		return v
	}
	return ""
}

func parseStringSlice(v any) []string {
	if v == nil {
		return []string{}
	}
	if arr, ok := v.([]any); ok {
		var result []string
		for _, item := range arr {
			if s, ok := item.(string); ok {
				result = append(result, s)
			}
		}
		return result
	}
	return []string{}
}

func intParam(params map[string]any, key string, defaultVal int) int {
	if v, ok := params[key]; ok {
		switch n := v.(type) {
		case float64:
			return int(n)
		case int:
			return n
		}
	}
	return defaultVal
}

func defaultSocketPath() string {
	if v := os.Getenv("CMUX_CONTEXT_SOCKET_PATH"); v != "" {
		return v
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "cmux", "context.sock")
}

func defaultDBPath() string {
	if v := os.Getenv("CMUX_CONTEXT_DB_PATH"); v != "" {
		return v
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "cmux", "context.db")
}

// unused import guard
var _ = strings.TrimSpace
