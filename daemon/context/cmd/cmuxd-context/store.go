package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
)

// Store manages all context data in SQLite.
type Store struct {
	db *sql.DB
}

func NewStore(db *sql.DB) *Store {
	return &Store{db: db}
}

// --- Users ---

type User struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Role      string `json:"role"`
	Email     string `json:"email"`
	CreatedAt int64  `json:"created_at"`
}

func (s *Store) UserCreate(id, name, role, email string) (*User, error) {
	if id == "" {
		id = uuid.New().String()
	}
	now := time.Now().Unix()
	_, err := s.db.Exec(
		`INSERT INTO context_users (id, name, role, email, created_at) VALUES (?, ?, ?, ?, ?)
		 ON CONFLICT(id) DO UPDATE SET name = excluded.name, role = excluded.role, email = excluded.email`,
		id, name, role, email, now)
	if err != nil {
		return nil, fmt.Errorf("user create: %w", err)
	}
	return s.UserGet(id)
}

func (s *Store) UserGet(id string) (*User, error) {
	var u User
	err := s.db.QueryRow(
		`SELECT id, name, role, email, created_at FROM context_users WHERE id = ?`, id).
		Scan(&u.ID, &u.Name, &u.Role, &u.Email, &u.CreatedAt)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("user get: %w", err)
	}
	return &u, nil
}

func (s *Store) UserList() ([]User, error) {
	rows, err := s.db.Query(`SELECT id, name, role, email, created_at FROM context_users ORDER BY name`)
	if err != nil {
		return nil, fmt.Errorf("user list: %w", err)
	}
	defer rows.Close()
	var users []User
	for rows.Next() {
		var u User
		if err := rows.Scan(&u.ID, &u.Name, &u.Role, &u.Email, &u.CreatedAt); err != nil {
			return nil, err
		}
		users = append(users, u)
	}
	return users, rows.Err()
}

func (s *Store) UserDelete(id string) error {
	res, err := s.db.Exec(`DELETE FROM context_users WHERE id = ?`, id)
	if err != nil {
		return fmt.Errorf("user delete: %w", err)
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return fmt.Errorf("user not found: %s", id)
	}
	return nil
}

// --- Events / audit log ---

type Event struct {
	ID       int64  `json:"id"`
	Ts       int64  `json:"ts"`
	UserID   string `json:"user_id"`
	Action   string `json:"action"`
	Kind     string `json:"kind"`
	TargetID string `json:"target_id"`
	Summary  string `json:"summary"`
}

func (s *Store) LogEvent(userID, action, kind, targetID, summary string) {
	_, _ = s.db.Exec(
		`INSERT INTO context_events (user_id, action, kind, target_id, summary) VALUES (?, ?, ?, ?, ?)`,
		userID, action, kind, targetID, summary)
}

func (s *Store) EventList(limit int, userID string) ([]Event, error) {
	if limit <= 0 {
		limit = 50
	}
	var rows *sql.Rows
	var err error
	if userID != "" {
		rows, err = s.db.Query(
			`SELECT id, ts, user_id, action, kind, target_id, summary FROM context_events WHERE user_id = ? ORDER BY ts DESC LIMIT ?`,
			userID, limit)
	} else {
		rows, err = s.db.Query(
			`SELECT id, ts, user_id, action, kind, target_id, summary FROM context_events ORDER BY ts DESC LIMIT ?`,
			limit)
	}
	if err != nil {
		return nil, fmt.Errorf("event list: %w", err)
	}
	defer rows.Close()
	var events []Event
	for rows.Next() {
		var e Event
		if err := rows.Scan(&e.ID, &e.Ts, &e.UserID, &e.Action, &e.Kind, &e.TargetID, &e.Summary); err != nil {
			return nil, err
		}
		events = append(events, e)
	}
	return events, rows.Err()
}

// --- Key-Value ---

type KVEntry struct {
	Key       string   `json:"key"`
	Value     string   `json:"value"`
	Category  string   `json:"category"`
	Tags      []string `json:"tags"`
	CreatedBy string   `json:"created_by"`
	UpdatedBy string   `json:"updated_by"`
	CreatedAt int64    `json:"created_at"`
	UpdatedAt int64    `json:"updated_at"`
}

func (s *Store) KVGet(key string) (*KVEntry, error) {
	row := s.db.QueryRow(
		`SELECT key, value, category, tags, created_by, updated_by, created_at, updated_at
		 FROM context_kv WHERE key = ?`, key)
	return scanKVEntry(row)
}

func (s *Store) KVSet(key, value, category string, tags []string, author string) (*KVEntry, error) {
	tagsJSON, _ := json.Marshal(tags)
	now := time.Now().Unix()
	_, err := s.db.Exec(
		`INSERT INTO context_kv (key, value, category, tags, created_by, updated_by, created_at, updated_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?)
		 ON CONFLICT(key) DO UPDATE SET
			value = excluded.value,
			category = excluded.category,
			tags = excluded.tags,
			updated_by = excluded.updated_by,
			updated_at = excluded.updated_at`,
		key, value, category, string(tagsJSON), author, author, now, now)
	if err != nil {
		return nil, fmt.Errorf("kv set: %w", err)
	}
	return s.KVGet(key)
}

func (s *Store) KVDelete(key string) error {
	res, err := s.db.Exec(`DELETE FROM context_kv WHERE key = ?`, key)
	if err != nil {
		return fmt.Errorf("kv delete: %w", err)
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return fmt.Errorf("key not found: %s", key)
	}
	return nil
}

func (s *Store) KVList(category, prefix string) ([]KVEntry, error) {
	query := `SELECT key, value, category, tags, created_by, updated_by, created_at, updated_at FROM context_kv WHERE 1=1`
	var args []any
	if category != "" {
		query += ` AND category = ?`
		args = append(args, category)
	}
	if prefix != "" {
		query += ` AND key LIKE ?`
		args = append(args, prefix+"%")
	}
	query += ` ORDER BY key`

	rows, err := s.db.Query(query, args...)
	if err != nil {
		return nil, fmt.Errorf("kv list: %w", err)
	}
	defer rows.Close()

	var entries []KVEntry
	for rows.Next() {
		e, err := scanKVEntryFromRows(rows)
		if err != nil {
			return nil, err
		}
		entries = append(entries, *e)
	}
	return entries, rows.Err()
}

func scanKVEntry(row *sql.Row) (*KVEntry, error) {
	var e KVEntry
	var tagsJSON string
	err := row.Scan(&e.Key, &e.Value, &e.Category, &tagsJSON, &e.CreatedBy, &e.UpdatedBy, &e.CreatedAt, &e.UpdatedAt)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("scan kv: %w", err)
	}
	_ = json.Unmarshal([]byte(tagsJSON), &e.Tags)
	if e.Tags == nil {
		e.Tags = []string{}
	}
	return &e, nil
}

func scanKVEntryFromRows(rows *sql.Rows) (*KVEntry, error) {
	var e KVEntry
	var tagsJSON string
	err := rows.Scan(&e.Key, &e.Value, &e.Category, &tagsJSON, &e.CreatedBy, &e.UpdatedBy, &e.CreatedAt, &e.UpdatedAt)
	if err != nil {
		return nil, fmt.Errorf("scan kv row: %w", err)
	}
	_ = json.Unmarshal([]byte(tagsJSON), &e.Tags)
	if e.Tags == nil {
		e.Tags = []string{}
	}
	return &e, nil
}

// --- Documents ---

type Document struct {
	ID        string   `json:"id"`
	Title     string   `json:"title"`
	Body      string   `json:"body"`
	Category  string   `json:"category"`
	Tags      []string `json:"tags"`
	CreatedBy string   `json:"created_by"`
	UpdatedBy string   `json:"updated_by"`
	CreatedAt int64    `json:"created_at"`
	UpdatedAt int64    `json:"updated_at"`
}

func (s *Store) DocGet(id string) (*Document, error) {
	row := s.db.QueryRow(
		`SELECT id, title, body, category, tags, created_by, updated_by, created_at, updated_at
		 FROM context_docs WHERE id = ?`, id)
	return scanDocument(row)
}

func (s *Store) DocCreate(title, body, category string, tags []string, author string) (*Document, error) {
	id := uuid.New().String()
	tagsJSON, _ := json.Marshal(tags)
	now := time.Now().Unix()
	_, err := s.db.Exec(
		`INSERT INTO context_docs (id, title, body, category, tags, created_by, updated_by, created_at, updated_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		id, title, body, category, string(tagsJSON), author, author, now, now)
	if err != nil {
		return nil, fmt.Errorf("doc create: %w", err)
	}
	return s.DocGet(id)
}

func (s *Store) DocUpdate(id string, title, body *string, tags []string, category *string, author string) (*Document, error) {
	var sets []string
	var args []any
	now := time.Now().Unix()

	if title != nil {
		sets = append(sets, "title = ?")
		args = append(args, *title)
	}
	if body != nil {
		sets = append(sets, "body = ?")
		args = append(args, *body)
	}
	if category != nil {
		sets = append(sets, "category = ?")
		args = append(args, *category)
	}
	if tags != nil {
		tagsJSON, _ := json.Marshal(tags)
		sets = append(sets, "tags = ?")
		args = append(args, string(tagsJSON))
	}

	if len(sets) == 0 {
		return s.DocGet(id)
	}

	sets = append(sets, "updated_at = ?", "updated_by = ?")
	args = append(args, now, author)
	args = append(args, id)

	query := fmt.Sprintf(`UPDATE context_docs SET %s WHERE id = ?`, strings.Join(sets, ", "))
	res, err := s.db.Exec(query, args...)
	if err != nil {
		return nil, fmt.Errorf("doc update: %w", err)
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return nil, fmt.Errorf("document not found: %s", id)
	}
	return s.DocGet(id)
}

func (s *Store) DocDelete(id string) error {
	res, err := s.db.Exec(`DELETE FROM context_docs WHERE id = ?`, id)
	if err != nil {
		return fmt.Errorf("doc delete: %w", err)
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return fmt.Errorf("document not found: %s", id)
	}
	return nil
}

func (s *Store) DocList(category, tag string, limit, offset int) ([]Document, error) {
	query := `SELECT id, title, body, category, tags, created_by, updated_by, created_at, updated_at FROM context_docs WHERE 1=1`
	var args []any
	if category != "" {
		query += ` AND category = ?`
		args = append(args, category)
	}
	if tag != "" {
		query += ` AND json_each.value = ?`
		query = strings.Replace(query, "FROM context_docs", "FROM context_docs, json_each(context_docs.tags)", 1)
		args = append(args, tag)
	}
	query += ` ORDER BY updated_at DESC`
	if limit > 0 {
		query += fmt.Sprintf(` LIMIT %d`, limit)
	}
	if offset > 0 {
		query += fmt.Sprintf(` OFFSET %d`, offset)
	}

	rows, err := s.db.Query(query, args...)
	if err != nil {
		return nil, fmt.Errorf("doc list: %w", err)
	}
	defer rows.Close()

	var docs []Document
	for rows.Next() {
		d, err := scanDocumentFromRows(rows)
		if err != nil {
			return nil, err
		}
		docs = append(docs, *d)
	}
	return docs, rows.Err()
}

func (s *Store) DocSearch(query string) ([]Document, error) {
	rows, err := s.db.Query(
		`SELECT d.id, d.title, d.body, d.category, d.tags, d.created_by, d.updated_by, d.created_at, d.updated_at
		 FROM context_docs d
		 JOIN context_docs_fts fts ON d.rowid = fts.rowid
		 WHERE context_docs_fts MATCH ?
		 ORDER BY rank
		 LIMIT 50`, query)
	if err != nil {
		return nil, fmt.Errorf("doc search: %w", err)
	}
	defer rows.Close()

	var docs []Document
	for rows.Next() {
		d, err := scanDocumentFromRows(rows)
		if err != nil {
			return nil, err
		}
		docs = append(docs, *d)
	}
	return docs, rows.Err()
}

func scanDocument(row *sql.Row) (*Document, error) {
	var d Document
	var tagsJSON string
	err := row.Scan(&d.ID, &d.Title, &d.Body, &d.Category, &tagsJSON, &d.CreatedBy, &d.UpdatedBy, &d.CreatedAt, &d.UpdatedAt)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("scan doc: %w", err)
	}
	_ = json.Unmarshal([]byte(tagsJSON), &d.Tags)
	if d.Tags == nil {
		d.Tags = []string{}
	}
	return &d, nil
}

func scanDocumentFromRows(rows *sql.Rows) (*Document, error) {
	var d Document
	var tagsJSON string
	err := rows.Scan(&d.ID, &d.Title, &d.Body, &d.Category, &tagsJSON, &d.CreatedBy, &d.UpdatedBy, &d.CreatedAt, &d.UpdatedAt)
	if err != nil {
		return nil, fmt.Errorf("scan doc row: %w", err)
	}
	_ = json.Unmarshal([]byte(tagsJSON), &d.Tags)
	if d.Tags == nil {
		d.Tags = []string{}
	}
	return &d, nil
}

// --- Knowledge Graph: Entities ---

type Entity struct {
	ID         string         `json:"id"`
	Type       string         `json:"type"`
	Name       string         `json:"name"`
	Properties map[string]any `json:"properties"`
	CreatedBy  string         `json:"created_by"`
	UpdatedBy  string         `json:"updated_by"`
	CreatedAt  int64          `json:"created_at"`
	UpdatedAt  int64          `json:"updated_at"`
}

func (s *Store) EntityGet(id string) (*Entity, error) {
	row := s.db.QueryRow(
		`SELECT id, type, name, properties, created_by, updated_by, created_at, updated_at
		 FROM context_entities WHERE id = ?`, id)
	return scanEntity(row)
}

func (s *Store) EntityCreate(entityType, name string, properties map[string]any, author string) (*Entity, error) {
	id := uuid.New().String()
	propsJSON, _ := json.Marshal(properties)
	now := time.Now().Unix()
	_, err := s.db.Exec(
		`INSERT INTO context_entities (id, type, name, properties, created_by, updated_by, created_at, updated_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		id, entityType, name, string(propsJSON), author, author, now, now)
	if err != nil {
		return nil, fmt.Errorf("entity create: %w", err)
	}
	return s.EntityGet(id)
}

func (s *Store) EntityUpdate(id string, name *string, properties map[string]any, author string) (*Entity, error) {
	var sets []string
	var args []any
	now := time.Now().Unix()

	if name != nil {
		sets = append(sets, "name = ?")
		args = append(args, *name)
	}
	if properties != nil {
		propsJSON, _ := json.Marshal(properties)
		sets = append(sets, "properties = ?")
		args = append(args, string(propsJSON))
	}

	if len(sets) == 0 {
		return s.EntityGet(id)
	}

	sets = append(sets, "updated_at = ?", "updated_by = ?")
	args = append(args, now, author)
	args = append(args, id)

	query := fmt.Sprintf(`UPDATE context_entities SET %s WHERE id = ?`, strings.Join(sets, ", "))
	res, err := s.db.Exec(query, args...)
	if err != nil {
		return nil, fmt.Errorf("entity update: %w", err)
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return nil, fmt.Errorf("entity not found: %s", id)
	}
	return s.EntityGet(id)
}

func (s *Store) EntityDelete(id string) error {
	res, err := s.db.Exec(`DELETE FROM context_entities WHERE id = ?`, id)
	if err != nil {
		return fmt.Errorf("entity delete: %w", err)
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return fmt.Errorf("entity not found: %s", id)
	}
	return nil
}

func (s *Store) EntityList(entityType string, limit int) ([]Entity, error) {
	query := `SELECT id, type, name, properties, created_by, updated_by, created_at, updated_at FROM context_entities WHERE 1=1`
	var args []any
	if entityType != "" {
		query += ` AND type = ?`
		args = append(args, entityType)
	}
	query += ` ORDER BY name`
	if limit > 0 {
		query += fmt.Sprintf(` LIMIT %d`, limit)
	}

	rows, err := s.db.Query(query, args...)
	if err != nil {
		return nil, fmt.Errorf("entity list: %w", err)
	}
	defer rows.Close()

	var entities []Entity
	for rows.Next() {
		e, err := scanEntityFromRows(rows)
		if err != nil {
			return nil, err
		}
		entities = append(entities, *e)
	}
	return entities, rows.Err()
}

func scanEntity(row *sql.Row) (*Entity, error) {
	var e Entity
	var propsJSON string
	err := row.Scan(&e.ID, &e.Type, &e.Name, &propsJSON, &e.CreatedBy, &e.UpdatedBy, &e.CreatedAt, &e.UpdatedAt)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("scan entity: %w", err)
	}
	_ = json.Unmarshal([]byte(propsJSON), &e.Properties)
	if e.Properties == nil {
		e.Properties = map[string]any{}
	}
	return &e, nil
}

func scanEntityFromRows(rows *sql.Rows) (*Entity, error) {
	var e Entity
	var propsJSON string
	err := rows.Scan(&e.ID, &e.Type, &e.Name, &propsJSON, &e.CreatedBy, &e.UpdatedBy, &e.CreatedAt, &e.UpdatedAt)
	if err != nil {
		return nil, fmt.Errorf("scan entity row: %w", err)
	}
	_ = json.Unmarshal([]byte(propsJSON), &e.Properties)
	if e.Properties == nil {
		e.Properties = map[string]any{}
	}
	return &e, nil
}

// --- Knowledge Graph: Edges ---

type Edge struct {
	ID         string         `json:"id"`
	SourceID   string         `json:"source_id"`
	TargetID   string         `json:"target_id"`
	Relation   string         `json:"relation"`
	Properties map[string]any `json:"properties"`
	CreatedBy  string         `json:"created_by"`
	UpdatedBy  string         `json:"updated_by"`
	CreatedAt  int64          `json:"created_at"`
	UpdatedAt  int64          `json:"updated_at"`
}

func (s *Store) EdgeCreate(sourceID, targetID, relation string, properties map[string]any, author string) (*Edge, error) {
	id := uuid.New().String()
	propsJSON, _ := json.Marshal(properties)
	now := time.Now().Unix()
	_, err := s.db.Exec(
		`INSERT INTO context_edges (id, source_id, target_id, relation, properties, created_by, updated_by, created_at, updated_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		id, sourceID, targetID, relation, string(propsJSON), author, author, now, now)
	if err != nil {
		return nil, fmt.Errorf("edge create: %w", err)
	}
	return s.edgeGet(id)
}

func (s *Store) EdgeDelete(id string) error {
	res, err := s.db.Exec(`DELETE FROM context_edges WHERE id = ?`, id)
	if err != nil {
		return fmt.Errorf("edge delete: %w", err)
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return fmt.Errorf("edge not found: %s", id)
	}
	return nil
}

func (s *Store) EdgeList(entityID, relation, direction string) ([]Edge, error) {
	query := `SELECT id, source_id, target_id, relation, properties, created_by, updated_by, created_at, updated_at FROM context_edges WHERE 1=1`
	var args []any

	if entityID != "" {
		switch direction {
		case "outgoing":
			query += ` AND source_id = ?`
			args = append(args, entityID)
		case "incoming":
			query += ` AND target_id = ?`
			args = append(args, entityID)
		default:
			query += ` AND (source_id = ? OR target_id = ?)`
			args = append(args, entityID, entityID)
		}
	}
	if relation != "" {
		query += ` AND relation = ?`
		args = append(args, relation)
	}
	query += ` ORDER BY created_at DESC`

	rows, err := s.db.Query(query, args...)
	if err != nil {
		return nil, fmt.Errorf("edge list: %w", err)
	}
	defer rows.Close()

	var edges []Edge
	for rows.Next() {
		var e Edge
		var propsJSON string
		if err := rows.Scan(&e.ID, &e.SourceID, &e.TargetID, &e.Relation, &propsJSON, &e.CreatedBy, &e.UpdatedBy, &e.CreatedAt, &e.UpdatedAt); err != nil {
			return nil, fmt.Errorf("scan edge: %w", err)
		}
		_ = json.Unmarshal([]byte(propsJSON), &e.Properties)
		if e.Properties == nil {
			e.Properties = map[string]any{}
		}
		edges = append(edges, e)
	}
	return edges, rows.Err()
}

func (s *Store) edgeGet(id string) (*Edge, error) {
	var e Edge
	var propsJSON string
	err := s.db.QueryRow(
		`SELECT id, source_id, target_id, relation, properties, created_by, updated_by, created_at, updated_at
		 FROM context_edges WHERE id = ?`, id).
		Scan(&e.ID, &e.SourceID, &e.TargetID, &e.Relation, &propsJSON, &e.CreatedBy, &e.UpdatedBy, &e.CreatedAt, &e.UpdatedAt)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("scan edge: %w", err)
	}
	_ = json.Unmarshal([]byte(propsJSON), &e.Properties)
	if e.Properties == nil {
		e.Properties = map[string]any{}
	}
	return &e, nil
}
