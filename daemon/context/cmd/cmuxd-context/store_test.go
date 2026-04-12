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

func TestKVSetAndGet(t *testing.T) {
	_, store := setupTestDB(t)

	entry, err := store.KVSet("api_url", "https://api.example.com", "env", []string{"backend"}, "alice")
	if err != nil {
		t.Fatal(err)
	}
	if entry.Key != "api_url" || entry.Value != "https://api.example.com" {
		t.Fatalf("unexpected entry: %+v", entry)
	}

	got, err := store.KVGet("api_url")
	if err != nil {
		t.Fatal(err)
	}
	if got == nil || got.Value != "https://api.example.com" {
		t.Fatalf("expected api_url, got %+v", got)
	}
}

func TestKVUpsert(t *testing.T) {
	_, store := setupTestDB(t)

	store.KVSet("key1", "value1", "", nil, "")
	store.KVSet("key1", "value2", "updated", nil, "")

	got, _ := store.KVGet("key1")
	if got.Value != "value2" || got.Category != "updated" {
		t.Fatalf("upsert failed: %+v", got)
	}
}

func TestKVList(t *testing.T) {
	_, store := setupTestDB(t)

	store.KVSet("env.staging", "s", "env", nil, "")
	store.KVSet("env.prod", "p", "env", nil, "")
	store.KVSet("flag.beta", "true", "flags", nil, "")

	entries, err := store.KVList("env", "")
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 2 {
		t.Fatalf("expected 2 env entries, got %d", len(entries))
	}

	entries, _ = store.KVList("", "env.")
	if len(entries) != 2 {
		t.Fatalf("expected 2 prefix entries, got %d", len(entries))
	}
}

func TestKVDelete(t *testing.T) {
	_, store := setupTestDB(t)

	store.KVSet("tmp", "val", "", nil, "")
	if err := store.KVDelete("tmp"); err != nil {
		t.Fatal(err)
	}
	got, _ := store.KVGet("tmp")
	if got != nil {
		t.Fatal("expected nil after delete")
	}
}

func TestDocCreateAndSearch(t *testing.T) {
	_, store := setupTestDB(t)

	doc, err := store.DocCreate("Auth Flow", "The authentication uses JWT tokens with refresh rotation.", "auth", []string{"security"}, "bob")
	if err != nil {
		t.Fatal(err)
	}
	if doc.Title != "Auth Flow" {
		t.Fatalf("unexpected doc: %+v", doc)
	}

	results, err := store.DocSearch("JWT tokens")
	if err != nil {
		t.Fatal(err)
	}
	if len(results) != 1 || results[0].ID != doc.ID {
		t.Fatalf("FTS search failed, got %d results", len(results))
	}
}

func TestDocUpdate(t *testing.T) {
	_, store := setupTestDB(t)

	doc, _ := store.DocCreate("Draft", "initial body", "", nil, "")
	newTitle := "Final"
	newBody := "updated body"
	updated, err := store.DocUpdate(doc.ID, &newTitle, &newBody, nil, nil, "")
	if err != nil {
		t.Fatal(err)
	}
	if updated.Title != "Final" || updated.Body != "updated body" {
		t.Fatalf("update failed: %+v", updated)
	}
}

func TestDocList(t *testing.T) {
	_, store := setupTestDB(t)

	store.DocCreate("Doc A", "", "arch", nil, "")
	store.DocCreate("Doc B", "", "arch", nil, "")
	store.DocCreate("Doc C", "", "ops", nil, "")

	docs, _ := store.DocList("arch", "", 0, 0)
	if len(docs) != 2 {
		t.Fatalf("expected 2, got %d", len(docs))
	}
}

func TestEntityCreateAndList(t *testing.T) {
	_, store := setupTestDB(t)

	e1, err := store.EntityCreate("service", "api-gateway", map[string]any{"port": 8080}, "")
	if err != nil {
		t.Fatal(err)
	}
	if e1.Name != "api-gateway" {
		t.Fatalf("unexpected: %+v", e1)
	}

	store.EntityCreate("service", "auth-svc", nil, "")
	store.EntityCreate("person", "Alice", nil, "")

	services, _ := store.EntityList("service", 0)
	if len(services) != 2 {
		t.Fatalf("expected 2 services, got %d", len(services))
	}

	all, _ := store.EntityList("", 0)
	if len(all) != 3 {
		t.Fatalf("expected 3 total, got %d", len(all))
	}
}

func TestEdgeCreateAndList(t *testing.T) {
	_, store := setupTestDB(t)

	e1, _ := store.EntityCreate("service", "gateway", nil, "")
	e2, _ := store.EntityCreate("service", "auth", nil, "")

	edge, err := store.EdgeCreate(e1.ID, e2.ID, "depends_on", map[string]any{"protocol": "gRPC"}, "")
	if err != nil {
		t.Fatal(err)
	}
	if edge.Relation != "depends_on" {
		t.Fatalf("unexpected edge: %+v", edge)
	}

	edges, _ := store.EdgeList(e1.ID, "", "outgoing")
	if len(edges) != 1 {
		t.Fatalf("expected 1 outgoing edge, got %d", len(edges))
	}

	edges, _ = store.EdgeList(e2.ID, "", "incoming")
	if len(edges) != 1 {
		t.Fatalf("expected 1 incoming edge, got %d", len(edges))
	}
}

func TestEdgeCascadeDelete(t *testing.T) {
	_, store := setupTestDB(t)

	e1, _ := store.EntityCreate("service", "a", nil, "")
	e2, _ := store.EntityCreate("service", "b", nil, "")
	store.EdgeCreate(e1.ID, e2.ID, "uses", nil, "")

	// Delete entity should cascade delete edges
	store.EntityDelete(e1.ID)
	edges, _ := store.EdgeList(e1.ID, "", "")
	if len(edges) != 0 {
		t.Fatalf("expected 0 edges after cascade, got %d", len(edges))
	}
}

func TestUnifiedSearch(t *testing.T) {
	_, store := setupTestDB(t)

	store.KVSet("staging_url", "https://staging.test.com", "env", nil, "")
	store.DocCreate("Staging Guide", "How to deploy to staging environment", "", nil, "")
	store.EntityCreate("service", "staging-proxy", nil, "")

	results, err := store.UnifiedSearch("staging")
	if err != nil {
		t.Fatal(err)
	}
	if len(results) < 2 {
		t.Fatalf("expected at least 2 results, got %d", len(results))
	}
}

func TestExportImport(t *testing.T) {
	_, store := setupTestDB(t)

	store.KVSet("k1", "v1", "", nil, "")
	store.DocCreate("Doc1", "body1", "", nil, "")
	e1, _ := store.EntityCreate("service", "svc1", nil, "")
	e2, _ := store.EntityCreate("service", "svc2", nil, "")
	store.EdgeCreate(e1.ID, e2.ID, "calls", nil, "")

	exported, err := store.Export()
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
	counts, err := store2.Import(roundtripped)
	if err != nil {
		t.Fatal(err)
	}
	if counts["kv"] != 1 || counts["docs"] != 1 || counts["entities"] != 2 || counts["edges"] != 1 {
		t.Fatalf("unexpected import counts: %+v", counts)
	}
}
