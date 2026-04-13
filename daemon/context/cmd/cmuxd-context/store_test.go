package main

import (
	"database/sql"
	"encoding/json"
	"os"
	"testing"

	_ "modernc.org/sqlite"
)

func setupTestDB(t *testing.T) (*sql.DB, *Store) {
	t.Helper()
	tmpFile, err := os.CreateTemp("", "context-test-*.db")
	if err != nil {
		t.Fatal(err)
	}
	tmpFile.Close()
	t.Cleanup(func() { os.Remove(tmpFile.Name()) })

	db, err := sql.Open("sqlite", tmpFile.Name())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })

	db.SetMaxOpenConns(1)
	if err := initSchema(db); err != nil {
		t.Fatal(err)
	}

	return db, NewStore(db)
}

// p is the default test project (empty = DefaultProjectID via normalization).
const p = ""

func TestKVSetAndGet(t *testing.T) {
	_, store := setupTestDB(t)

	entry, err := store.KVSet(p, "api_url", "https://api.example.com", "env", []string{"backend"}, "alice")
	if err != nil {
		t.Fatal(err)
	}
	if entry.Key != "api_url" || entry.Value != "https://api.example.com" {
		t.Fatalf("unexpected entry: %+v", entry)
	}

	got, err := store.KVGet(p, "api_url")
	if err != nil {
		t.Fatal(err)
	}
	if got == nil || got.Value != "https://api.example.com" {
		t.Fatalf("expected api_url, got %+v", got)
	}
}

func TestKVUpsert(t *testing.T) {
	_, store := setupTestDB(t)

	store.KVSet(p, "key1", "value1", "", nil, "")
	store.KVSet(p, "key1", "value2", "updated", nil, "")

	got, _ := store.KVGet(p, "key1")
	if got.Value != "value2" || got.Category != "updated" {
		t.Fatalf("upsert failed: %+v", got)
	}
}

func TestKVList(t *testing.T) {
	_, store := setupTestDB(t)

	store.KVSet(p, "env.staging", "s", "env", nil, "")
	store.KVSet(p, "env.prod", "p", "env", nil, "")
	store.KVSet(p, "flag.beta", "true", "flags", nil, "")

	entries, err := store.KVList(p, "env", "")
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 2 {
		t.Fatalf("expected 2 env entries, got %d", len(entries))
	}

	entries, _ = store.KVList(p, "", "env.")
	if len(entries) != 2 {
		t.Fatalf("expected 2 prefix entries, got %d", len(entries))
	}
}

func TestKVDelete(t *testing.T) {
	_, store := setupTestDB(t)

	store.KVSet(p, "tmp", "val", "", nil, "")
	if err := store.KVDelete(p, "tmp"); err != nil {
		t.Fatal(err)
	}
	got, _ := store.KVGet(p, "tmp")
	if got != nil {
		t.Fatal("expected nil after delete")
	}
}

func TestDocCreateAndSearch(t *testing.T) {
	_, store := setupTestDB(t)

	doc, err := store.DocCreate(p, "Auth Flow", "The authentication uses JWT tokens with refresh rotation.", "auth", []string{"security"}, "bob")
	if err != nil {
		t.Fatal(err)
	}
	if doc.Title != "Auth Flow" {
		t.Fatalf("unexpected doc: %+v", doc)
	}

	results, err := store.DocSearch(p, "JWT tokens")
	if err != nil {
		t.Fatal(err)
	}
	if len(results) != 1 || results[0].ID != doc.ID {
		t.Fatalf("FTS search failed, got %d results", len(results))
	}
}

func TestDocUpdate(t *testing.T) {
	_, store := setupTestDB(t)

	doc, _ := store.DocCreate(p, "Draft", "initial body", "", nil, "")
	newTitle := "Final"
	newBody := "updated body"
	updated, err := store.DocUpdate(p, doc.ID, &newTitle, &newBody, nil, nil, "")
	if err != nil {
		t.Fatal(err)
	}
	if updated.Title != "Final" || updated.Body != "updated body" {
		t.Fatalf("update failed: %+v", updated)
	}
}

func TestDocList(t *testing.T) {
	_, store := setupTestDB(t)

	store.DocCreate(p, "Doc A", "", "arch", nil, "")
	store.DocCreate(p, "Doc B", "", "arch", nil, "")
	store.DocCreate(p, "Doc C", "", "ops", nil, "")

	docs, _ := store.DocList(p, "arch", "", 0, 0)
	if len(docs) != 2 {
		t.Fatalf("expected 2, got %d", len(docs))
	}
}

func TestEntityCreateAndList(t *testing.T) {
	_, store := setupTestDB(t)

	e1, err := store.EntityCreate(p, "service", "api-gateway", map[string]any{"port": 8080}, "")
	if err != nil {
		t.Fatal(err)
	}
	if e1.Name != "api-gateway" {
		t.Fatalf("unexpected: %+v", e1)
	}

	store.EntityCreate(p, "service", "auth-svc", nil, "")
	store.EntityCreate(p, "person", "Alice", nil, "")

	services, _ := store.EntityList(p, "service", 0)
	if len(services) != 2 {
		t.Fatalf("expected 2 services, got %d", len(services))
	}

	all, _ := store.EntityList(p, "", 0)
	if len(all) != 3 {
		t.Fatalf("expected 3 total, got %d", len(all))
	}
}

func TestEdgeCreateAndList(t *testing.T) {
	_, store := setupTestDB(t)

	e1, _ := store.EntityCreate(p, "service", "gateway", nil, "")
	e2, _ := store.EntityCreate(p, "service", "auth", nil, "")

	edge, err := store.EdgeCreate(p, e1.ID, e2.ID, "depends_on", map[string]any{"protocol": "gRPC"}, "")
	if err != nil {
		t.Fatal(err)
	}
	if edge.Relation != "depends_on" {
		t.Fatalf("unexpected edge: %+v", edge)
	}

	edges, _ := store.EdgeList(p, e1.ID, "", "outgoing")
	if len(edges) != 1 {
		t.Fatalf("expected 1 outgoing edge, got %d", len(edges))
	}

	edges, _ = store.EdgeList(p, e2.ID, "", "incoming")
	if len(edges) != 1 {
		t.Fatalf("expected 1 incoming edge, got %d", len(edges))
	}
}

func TestEdgeCascadeDelete(t *testing.T) {
	_, store := setupTestDB(t)

	e1, _ := store.EntityCreate(p, "service", "a", nil, "")
	e2, _ := store.EntityCreate(p, "service", "b", nil, "")
	store.EdgeCreate(p, e1.ID, e2.ID, "uses", nil, "")

	// Delete entity should cascade delete edges
	store.EntityDelete(p, e1.ID)
	edges, _ := store.EdgeList(p, e1.ID, "", "")
	if len(edges) != 0 {
		t.Fatalf("expected 0 edges after cascade, got %d", len(edges))
	}
}

func TestUnifiedSearch(t *testing.T) {
	_, store := setupTestDB(t)

	store.KVSet(p, "staging_url", "https://staging.test.com", "env", nil, "")
	store.DocCreate(p, "Staging Guide", "How to deploy to staging environment", "", nil, "")
	store.EntityCreate(p, "service", "staging-proxy", nil, "")

	results, err := store.UnifiedSearch(p, "staging")
	if err != nil {
		t.Fatal(err)
	}
	if len(results) < 2 {
		t.Fatalf("expected at least 2 results, got %d", len(results))
	}
}

func TestExportImport(t *testing.T) {
	_, store := setupTestDB(t)

	store.KVSet(p, "k1", "v1", "", nil, "")
	store.DocCreate(p, "Doc1", "body1", "", nil, "")
	e1, _ := store.EntityCreate(p, "service", "svc1", nil, "")
	e2, _ := store.EntityCreate(p, "service", "svc2", nil, "")
	store.EdgeCreate(p, e1.ID, e2.ID, "calls", nil, "")

	exported, err := store.Export(p)
	if err != nil {
		t.Fatal(err)
	}

	// JSON roundtrip to simulate real export/import (structs → map[string]any)
	b, err := json.Marshal(exported)
	if err != nil {
		t.Fatal(err)
	}
	var roundtripped map[string]any
	if err := json.Unmarshal(b, &roundtripped); err != nil {
		t.Fatal(err)
	}

	// Import into fresh store
	_, store2 := setupTestDB(t)
	counts, err := store2.Import(p, roundtripped)
	if err != nil {
		t.Fatal(err)
	}
	if counts["kv"] != 1 || counts["docs"] != 1 || counts["entities"] != 2 || counts["edges"] != 1 {
		t.Fatalf("unexpected import counts: %+v", counts)
	}
}

// TestProjectIsolation verifies the same key can coexist across projects.
func TestProjectIsolation(t *testing.T) {
	_, store := setupTestDB(t)

	proj, err := store.ProjectCreate("Other", "u")
	if err != nil {
		t.Fatal(err)
	}

	store.KVSet(p, "shared", "default-val", "", nil, "")
	store.KVSet(proj.ID, "shared", "other-val", "", nil, "")

	a, _ := store.KVGet(p, "shared")
	b, _ := store.KVGet(proj.ID, "shared")
	if a == nil || b == nil || a.Value == b.Value {
		t.Fatalf("expected isolated values, got a=%+v b=%+v", a, b)
	}

	aList, _ := store.KVList(p, "", "")
	bList, _ := store.KVList(proj.ID, "", "")
	if len(aList) != 1 || len(bList) != 1 {
		t.Fatalf("expected 1 entry each project, got default=%d other=%d", len(aList), len(bList))
	}
}
