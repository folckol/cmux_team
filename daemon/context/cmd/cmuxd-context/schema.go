package main

import (
	"database/sql"
	"fmt"
)

const schemaVersion = 5

// DefaultProjectID is the id assigned to data that existed before the
// multi-project schema (v4). New clients that don't specify a project also
// land here so the daemon stays backward-compatible.
const DefaultProjectID = "default"

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
	if currentVersion < 3 {
		if err := migrateV3(tx); err != nil {
			return fmt.Errorf("migrate v3: %w", err)
		}
	}
	if currentVersion < 4 {
		if err := migrateV4(tx); err != nil {
			return fmt.Errorf("migrate v4: %w", err)
		}
	}
	if currentVersion < 5 {
		if err := migrateV5(tx); err != nil {
			return fmt.Errorf("migrate v5: %w", err)
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

func migrateV3(tx *sql.Tx) error {
	stmts := []string{
		`ALTER TABLE context_docs ADD COLUMN line_authors TEXT NOT NULL DEFAULT '[]'`,
	}
	for _, stmt := range stmts {
		if _, err := tx.Exec(stmt); err != nil {
			return fmt.Errorf("exec %q: %w", stmt[:min(len(stmt), 60)], err)
		}
	}
	return nil
}

// migrateV4 introduces multi-project support. A `context_projects` table
// is created; every data table gets a `project_id` column (default
// DefaultProjectID so existing rows are preserved). KV needs a composite
// PK, so the table is rebuilt via a rename+copy.
func migrateV4(tx *sql.Tx) error {
	stmts := []string{
		`CREATE TABLE IF NOT EXISTS context_projects (
			id         TEXT PRIMARY KEY,
			name       TEXT NOT NULL UNIQUE,
			created_by TEXT NOT NULL DEFAULT '',
			created_at INTEGER NOT NULL DEFAULT (unixepoch())
		)`,

		// Seed default project so old rows remain queryable.
		`INSERT OR IGNORE INTO context_projects (id, name, created_at) VALUES ('default', 'Default', unixepoch())`,

		// Docs / entities / edges / events: single-column add, PK stays (UUID / auto id).
		`ALTER TABLE context_docs     ADD COLUMN project_id TEXT NOT NULL DEFAULT 'default'`,
		`ALTER TABLE context_entities ADD COLUMN project_id TEXT NOT NULL DEFAULT 'default'`,
		`ALTER TABLE context_edges    ADD COLUMN project_id TEXT NOT NULL DEFAULT 'default'`,
		`ALTER TABLE context_events   ADD COLUMN project_id TEXT NOT NULL DEFAULT 'default'`,

		`CREATE INDEX IF NOT EXISTS idx_docs_project     ON context_docs(project_id)`,
		`CREATE INDEX IF NOT EXISTS idx_entities_project ON context_entities(project_id)`,
		`CREATE INDEX IF NOT EXISTS idx_edges_project    ON context_edges(project_id)`,
		`CREATE INDEX IF NOT EXISTS idx_events_project   ON context_events(project_id)`,

		// KV: key was PK, but it must be unique only per-project now.
		// Rebuild the table with (project_id, key) composite PK.
		`ALTER TABLE context_kv RENAME TO context_kv_old_v3`,

		`CREATE TABLE context_kv (
			project_id TEXT NOT NULL DEFAULT 'default',
			key        TEXT NOT NULL,
			value      TEXT NOT NULL,
			category   TEXT NOT NULL DEFAULT '',
			tags       TEXT NOT NULL DEFAULT '[]',
			created_by TEXT NOT NULL DEFAULT '',
			updated_by TEXT NOT NULL DEFAULT '',
			created_at INTEGER NOT NULL DEFAULT (unixepoch()),
			updated_at INTEGER NOT NULL DEFAULT (unixepoch()),
			PRIMARY KEY (project_id, key)
		)`,

		`INSERT INTO context_kv (project_id, key, value, category, tags, created_by, updated_by, created_at, updated_at)
		 SELECT 'default', key, value, category, tags, created_by, updated_by, created_at, updated_at FROM context_kv_old_v3`,

		`DROP TABLE context_kv_old_v3`,

		`CREATE INDEX IF NOT EXISTS idx_kv_project_category ON context_kv(project_id, category)`,
	}

	for _, stmt := range stmts {
		if _, err := tx.Exec(stmt); err != nil {
			return fmt.Errorf("exec %q: %w", stmt[:min(len(stmt), 60)], err)
		}
	}
	return nil
}

// migrateV5 introduces user/project access control:
//   - users gain an `is_admin` flag (server-wide super-user).
//   - projects gain an optional password (sha256 + per-project salt).
//   - new `context_project_members` table tracks who joined which project.
// Existing data: pre-v5 projects have no password (NULL), so existing
// sessions can keep using the default project until an admin sets one.
// First user created after upgrade automatically becomes the bootstrap admin
// (handled in main.go, not the migration).
func migrateV5(tx *sql.Tx) error {
	stmts := []string{
		`ALTER TABLE context_users ADD COLUMN is_admin INTEGER NOT NULL DEFAULT 0`,

		`ALTER TABLE context_projects ADD COLUMN password_hash TEXT NOT NULL DEFAULT ''`,
		`ALTER TABLE context_projects ADD COLUMN password_salt TEXT NOT NULL DEFAULT ''`,

		`CREATE TABLE IF NOT EXISTS context_project_members (
			project_id TEXT NOT NULL,
			user_id    TEXT NOT NULL,
			role       TEXT NOT NULL DEFAULT '',
			joined_at  INTEGER NOT NULL DEFAULT (unixepoch()),
			PRIMARY KEY (project_id, user_id)
		)`,
		`CREATE INDEX IF NOT EXISTS idx_members_user    ON context_project_members(user_id)`,
		`CREATE INDEX IF NOT EXISTS idx_members_project ON context_project_members(project_id)`,

		// Backfill: every pre-existing user becomes a member of the default
		// project so legacy clients keep working after the upgrade. New
		// projects start empty and require an explicit join.
		`INSERT OR IGNORE INTO context_project_members (project_id, user_id, role, joined_at)
		 SELECT 'default', id, '', unixepoch() FROM context_users`,

		// Also seed every existing project with its creator as the first
		// "owner" member. Covers projects that were created between the v4
		// rollout and the membership feature, or edge cases where the
		// in-code ProjectCreate membership insert silently failed.
		`INSERT OR IGNORE INTO context_project_members (project_id, user_id, role, joined_at)
		 SELECT id, created_by, 'owner', unixepoch() FROM context_projects
		 WHERE created_by != ''`,

		// Bootstrap admin: promote the earliest user that exists at upgrade
		// time, so teams upgrading from v4 don't end up without any admin.
		// Only runs when no admin already exists (idempotent on re-runs and
		// doesn't touch manually-set admins).
		`UPDATE context_users SET is_admin = 1
		 WHERE id = (
			 SELECT id FROM context_users ORDER BY created_at ASC, id ASC LIMIT 1
		 )
		 AND NOT EXISTS (SELECT 1 FROM context_users WHERE is_admin = 1)`,
	}
	for _, stmt := range stmts {
		if _, err := tx.Exec(stmt); err != nil {
			return fmt.Errorf("exec %q: %w", stmt[:min(len(stmt), 60)], err)
		}
	}
	return nil
}
