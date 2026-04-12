package main

import (
	"database/sql"
	"fmt"
)

const schemaVersion = 2

func initSchema(db *sql.DB) error {
	if _, err := db.Exec("PRAGMA journal_mode=WAL"); err != nil {
		return fmt.Errorf("enable WAL: %w", err)
	}
	if _, err := db.Exec("PRAGMA foreign_keys=ON"); err != nil {
		return fmt.Errorf("enable foreign keys: %w", err)
	}

	var currentVersion int
	if err := db.QueryRow("PRAGMA user_version").Scan(&currentVersion); err != nil {
		return fmt.Errorf("read user_version: %w", err)
	}

	if currentVersion >= schemaVersion {
		return nil
	}

	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("begin migration tx: %w", err)
	}
	defer tx.Rollback()

	if currentVersion < 1 {
		if err := migrateV1(tx); err != nil {
			return fmt.Errorf("migrate v1: %w", err)
		}
	}
	if currentVersion < 2 {
		if err := migrateV2(tx); err != nil {
			return fmt.Errorf("migrate v2: %w", err)
		}
	}

	if _, err := tx.Exec(fmt.Sprintf("PRAGMA user_version = %d", schemaVersion)); err != nil {
		return fmt.Errorf("set user_version: %w", err)
	}

	return tx.Commit()
}

func migrateV1(tx *sql.Tx) error {
	stmts := []string{
		`CREATE TABLE IF NOT EXISTS context_kv (
			key        TEXT PRIMARY KEY,
			value      TEXT NOT NULL,
			category   TEXT NOT NULL DEFAULT '',
			tags       TEXT NOT NULL DEFAULT '[]',
			created_by TEXT NOT NULL DEFAULT '',
			created_at INTEGER NOT NULL DEFAULT (unixepoch()),
			updated_at INTEGER NOT NULL DEFAULT (unixepoch())
		)`,

		`CREATE INDEX IF NOT EXISTS idx_kv_category ON context_kv(category)`,

		`CREATE TABLE IF NOT EXISTS context_docs (
			id         TEXT PRIMARY KEY,
			title      TEXT NOT NULL,
			body       TEXT NOT NULL DEFAULT '',
			category   TEXT NOT NULL DEFAULT '',
			tags       TEXT NOT NULL DEFAULT '[]',
			created_by TEXT NOT NULL DEFAULT '',
			created_at INTEGER NOT NULL DEFAULT (unixepoch()),
			updated_at INTEGER NOT NULL DEFAULT (unixepoch())
		)`,

		`CREATE INDEX IF NOT EXISTS idx_docs_category ON context_docs(category)`,

		`CREATE VIRTUAL TABLE IF NOT EXISTS context_docs_fts USING fts5(
			title, body, content=context_docs, content_rowid=rowid
		)`,

		// FTS triggers for keeping index in sync
		`CREATE TRIGGER IF NOT EXISTS context_docs_ai AFTER INSERT ON context_docs BEGIN
			INSERT INTO context_docs_fts(rowid, title, body) VALUES (new.rowid, new.title, new.body);
		END`,

		`CREATE TRIGGER IF NOT EXISTS context_docs_ad AFTER DELETE ON context_docs BEGIN
			INSERT INTO context_docs_fts(context_docs_fts, rowid, title, body) VALUES('delete', old.rowid, old.title, old.body);
		END`,

		`CREATE TRIGGER IF NOT EXISTS context_docs_au AFTER UPDATE ON context_docs BEGIN
			INSERT INTO context_docs_fts(context_docs_fts, rowid, title, body) VALUES('delete', old.rowid, old.title, old.body);
			INSERT INTO context_docs_fts(rowid, title, body) VALUES (new.rowid, new.title, new.body);
		END`,

		`CREATE TABLE IF NOT EXISTS context_entities (
			id         TEXT PRIMARY KEY,
			type       TEXT NOT NULL,
			name       TEXT NOT NULL,
			properties TEXT NOT NULL DEFAULT '{}',
			created_at INTEGER NOT NULL DEFAULT (unixepoch()),
			updated_at INTEGER NOT NULL DEFAULT (unixepoch())
		)`,

		`CREATE INDEX IF NOT EXISTS idx_entities_type ON context_entities(type)`,

		`CREATE TABLE IF NOT EXISTS context_edges (
			id         TEXT PRIMARY KEY,
			source_id  TEXT NOT NULL REFERENCES context_entities(id) ON DELETE CASCADE,
			target_id  TEXT NOT NULL REFERENCES context_entities(id) ON DELETE CASCADE,
			relation   TEXT NOT NULL,
			properties TEXT NOT NULL DEFAULT '{}',
			created_at INTEGER NOT NULL DEFAULT (unixepoch()),
			updated_at INTEGER NOT NULL DEFAULT (unixepoch())
		)`,

		`CREATE INDEX IF NOT EXISTS idx_edges_source ON context_edges(source_id)`,
		`CREATE INDEX IF NOT EXISTS idx_edges_target ON context_edges(target_id)`,
		`CREATE INDEX IF NOT EXISTS idx_edges_relation ON context_edges(relation)`,
	}

	for _, stmt := range stmts {
		if _, err := tx.Exec(stmt); err != nil {
			return fmt.Errorf("exec %q: %w", stmt[:min(len(stmt), 60)], err)
		}
	}

	return nil
}

func migrateV2(tx *sql.Tx) error {
	stmts := []string{
		`CREATE TABLE IF NOT EXISTS context_users (
			id         TEXT PRIMARY KEY,
			name       TEXT NOT NULL,
			role       TEXT NOT NULL DEFAULT '',
			email      TEXT NOT NULL DEFAULT '',
			created_at INTEGER NOT NULL DEFAULT (unixepoch())
		)`,

		`ALTER TABLE context_kv       ADD COLUMN updated_by TEXT NOT NULL DEFAULT ''`,
		`ALTER TABLE context_docs     ADD COLUMN updated_by TEXT NOT NULL DEFAULT ''`,
		`ALTER TABLE context_entities ADD COLUMN created_by TEXT NOT NULL DEFAULT ''`,
		`ALTER TABLE context_entities ADD COLUMN updated_by TEXT NOT NULL DEFAULT ''`,
		`ALTER TABLE context_edges    ADD COLUMN created_by TEXT NOT NULL DEFAULT ''`,
		`ALTER TABLE context_edges    ADD COLUMN updated_by TEXT NOT NULL DEFAULT ''`,

		`CREATE TABLE IF NOT EXISTS context_events (
			id         INTEGER PRIMARY KEY AUTOINCREMENT,
			ts         INTEGER NOT NULL DEFAULT (unixepoch()),
			user_id    TEXT NOT NULL DEFAULT '',
			action     TEXT NOT NULL,
			kind       TEXT NOT NULL,
			target_id  TEXT NOT NULL DEFAULT '',
			summary    TEXT NOT NULL DEFAULT ''
		)`,
		`CREATE INDEX IF NOT EXISTS idx_events_ts ON context_events(ts DESC)`,
		`CREATE INDEX IF NOT EXISTS idx_events_user ON context_events(user_id)`,
	}

	for _, stmt := range stmts {
		if _, err := tx.Exec(stmt); err != nil {
			return fmt.Errorf("exec %q: %w", stmt[:min(len(stmt), 60)], err)
		}
	}
	return nil
}
