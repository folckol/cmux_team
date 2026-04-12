package main

import "encoding/json"

// SearchResult represents a unified search result across all stores.
type SearchResult struct {
	Type    string `json:"type"` // "kv", "doc", "entity"
	ID      string `json:"id"`
	Title   string `json:"title"`
	Snippet string `json:"snippet"`
	Score   int    `json:"score"`
}

// UnifiedSearch searches across KV entries, documents (FTS5), and entities.
func (s *Store) UnifiedSearch(query string) ([]SearchResult, error) {
	var results []SearchResult

	// Search KV by key and value
	kvRows, err := s.db.Query(
		`SELECT key, value, category FROM context_kv
		 WHERE key LIKE ? OR value LIKE ?
		 LIMIT 20`,
		"%"+query+"%", "%"+query+"%")
	if err == nil {
		defer kvRows.Close()
		for kvRows.Next() {
			var key, value, category string
			if err := kvRows.Scan(&key, &value, &category); err == nil {
				snippet := value
				if len(snippet) > 100 {
					snippet = snippet[:100] + "..."
				}
				results = append(results, SearchResult{
					Type:    "kv",
					ID:      key,
					Title:   key,
					Snippet: snippet,
					Score:   1,
				})
			}
		}
	}

	// Search documents via FTS5
	docRows, err := s.db.Query(
		`SELECT d.id, d.title, snippet(context_docs_fts, 1, '<mark>', '</mark>', '...', 32)
		 FROM context_docs d
		 JOIN context_docs_fts fts ON d.rowid = fts.rowid
		 WHERE context_docs_fts MATCH ?
		 ORDER BY rank
		 LIMIT 20`, query)
	if err == nil {
		defer docRows.Close()
		for docRows.Next() {
			var id, title, snippet string
			if err := docRows.Scan(&id, &title, &snippet); err == nil {
				results = append(results, SearchResult{
					Type:    "doc",
					ID:      id,
					Title:   title,
					Snippet: snippet,
					Score:   2,
				})
			}
		}
	}

	// Search entities by name
	entityRows, err := s.db.Query(
		`SELECT id, type, name FROM context_entities
		 WHERE name LIKE ?
		 LIMIT 20`,
		"%"+query+"%")
	if err == nil {
		defer entityRows.Close()
		for entityRows.Next() {
			var id, entityType, name string
			if err := entityRows.Scan(&id, &entityType, &name); err == nil {
				results = append(results, SearchResult{
					Type:    "entity",
					ID:      id,
					Title:   name,
					Snippet: "type: " + entityType,
					Score:   1,
				})
			}
		}
	}

	return results, nil
}

// Export dumps all data as a single JSON-serializable structure.
func (s *Store) Export() (map[string]any, error) {
	kvEntries, err := s.KVList("", "")
	if err != nil {
		return nil, err
	}
	docs, err := s.DocList("", "", 0, 0)
	if err != nil {
		return nil, err
	}
	entities, err := s.EntityList("", 0)
	if err != nil {
		return nil, err
	}
	edges, err := s.EdgeList("", "", "")
	if err != nil {
		return nil, err
	}

	return map[string]any{
		"version":  1,
		"kv":       kvEntries,
		"docs":     docs,
		"entities": entities,
		"edges":    edges,
	}, nil
}

// Import loads data from an exported JSON structure.
func (s *Store) Import(data map[string]any) (map[string]int, error) {
	counts := map[string]int{"kv": 0, "docs": 0, "entities": 0, "edges": 0}

	tx, err := s.db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	// Import KV entries
	if raw, ok := data["kv"]; ok {
		if items, ok := raw.([]any); ok {
			for _, item := range items {
				m, ok := item.(map[string]any)
				if !ok {
					continue
				}
				key, _ := m["key"].(string)
				value, _ := m["value"].(string)
				category, _ := m["category"].(string)
				if key != "" {
					_, err := tx.Exec(
						`INSERT OR REPLACE INTO context_kv (key, value, category, updated_at)
						 VALUES (?, ?, ?, unixepoch())`, key, value, category)
					if err == nil {
						counts["kv"]++
					}
				}
			}
		}
	}

	// Import documents
	if raw, ok := data["docs"]; ok {
		if items, ok := raw.([]any); ok {
			for _, item := range items {
				m, ok := item.(map[string]any)
				if !ok {
					continue
				}
				id, _ := m["id"].(string)
				title, _ := m["title"].(string)
				body, _ := m["body"].(string)
				category, _ := m["category"].(string)
				if id != "" && title != "" {
					_, err := tx.Exec(
						`INSERT OR REPLACE INTO context_docs (id, title, body, category, updated_at)
						 VALUES (?, ?, ?, ?, unixepoch())`, id, title, body, category)
					if err == nil {
						counts["docs"]++
					}
				}
			}
		}
	}

	// Import entities
	if raw, ok := data["entities"]; ok {
		if items, ok := raw.([]any); ok {
			for _, item := range items {
				m, ok := item.(map[string]any)
				if !ok {
					continue
				}
				id, _ := m["id"].(string)
				entityType, _ := m["type"].(string)
				name, _ := m["name"].(string)
				propsJSON := "{}"
				if props, ok := m["properties"]; ok {
					if b, err := jsonMarshal(props); err == nil {
						propsJSON = string(b)
					}
				}
				if id != "" && name != "" {
					_, err := tx.Exec(
						`INSERT OR REPLACE INTO context_entities (id, type, name, properties, updated_at)
						 VALUES (?, ?, ?, ?, unixepoch())`, id, entityType, name, propsJSON)
					if err == nil {
						counts["entities"]++
					}
				}
			}
		}
	}

	// Import edges
	if raw, ok := data["edges"]; ok {
		if items, ok := raw.([]any); ok {
			for _, item := range items {
				m, ok := item.(map[string]any)
				if !ok {
					continue
				}
				id, _ := m["id"].(string)
				sourceID, _ := m["source_id"].(string)
				targetID, _ := m["target_id"].(string)
				relation, _ := m["relation"].(string)
				propsJSON := "{}"
				if props, ok := m["properties"]; ok {
					if b, err := jsonMarshal(props); err == nil {
						propsJSON = string(b)
					}
				}
				if id != "" && sourceID != "" && targetID != "" {
					_, err := tx.Exec(
						`INSERT OR REPLACE INTO context_edges (id, source_id, target_id, relation, properties, updated_at)
						 VALUES (?, ?, ?, ?, ?, unixepoch())`, id, sourceID, targetID, relation, propsJSON)
					if err == nil {
						counts["edges"]++
					}
				}
			}
		}
	}

	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return counts, nil
}

func jsonMarshal(v any) ([]byte, error) {
	return json.Marshal(v)
}
