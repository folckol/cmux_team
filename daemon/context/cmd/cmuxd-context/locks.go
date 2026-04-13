package main

import (
	"fmt"
	"strings"
	"sync"
	"time"
)

// LockManager provides short-lived edit locks on context items.
// Locks expire after TTL unless refreshed via heartbeat. In-memory only.
// Locks are scoped by project so the same target id in different projects
// can be edited independently.
type LockManager struct {
	mu    sync.Mutex
	locks map[string]*lockEntry // key = project + "\x00" + kind + "\x00" + id
	ttl   time.Duration
}

type lockEntry struct {
	UserID    string
	UserName  string
	ExpiresAt time.Time
}

type LockInfo struct {
	ProjectID string `json:"project_id"`
	Kind      string `json:"kind"`
	TargetID  string `json:"target_id"`
	UserID    string `json:"user_id"`
	UserName  string `json:"user_name"`
	ExpiresAt int64  `json:"expires_at"`
}

func NewLockManager() *LockManager {
	lm := &LockManager{
		locks: make(map[string]*lockEntry),
		ttl:   45 * time.Second,
	}
	go lm.gcLoop()
	return lm
}

const lockKeySep = "\x00"

func lockKey(projectID, kind, id string) string {
	return projectID + lockKeySep + kind + lockKeySep + id
}

func splitLockKey(k string) (string, string, string) {
	parts := strings.SplitN(k, lockKeySep, 3)
	switch len(parts) {
	case 3:
		return parts[0], parts[1], parts[2]
	case 2:
		return DefaultProjectID, parts[0], parts[1]
	default:
		return DefaultProjectID, k, ""
	}
}

// Acquire returns (ok, holderUserID, holderName). If already locked by another user, ok=false.
// If already locked by same user, it refreshes TTL.
func (lm *LockManager) Acquire(projectID, kind, id, userID, userName string) (bool, string, string) {
	projectID = normalizeProjectID(projectID)
	lm.mu.Lock()
	defer lm.mu.Unlock()
	k := lockKey(projectID, kind, id)
	now := time.Now()
	if e, ok := lm.locks[k]; ok && now.Before(e.ExpiresAt) {
		if e.UserID != userID {
			return false, e.UserID, e.UserName
		}
	}
	lm.locks[k] = &lockEntry{UserID: userID, UserName: userName, ExpiresAt: now.Add(lm.ttl)}
	return true, userID, userName
}

// Heartbeat extends TTL if caller holds the lock. Returns false if not held.
func (lm *LockManager) Heartbeat(projectID, kind, id, userID string) bool {
	projectID = normalizeProjectID(projectID)
	lm.mu.Lock()
	defer lm.mu.Unlock()
	k := lockKey(projectID, kind, id)
	e, ok := lm.locks[k]
	if !ok || e.UserID != userID {
		return false
	}
	e.ExpiresAt = time.Now().Add(lm.ttl)
	return true
}

func (lm *LockManager) Release(projectID, kind, id, userID string) {
	projectID = normalizeProjectID(projectID)
	lm.mu.Lock()
	defer lm.mu.Unlock()
	k := lockKey(projectID, kind, id)
	if e, ok := lm.locks[k]; ok && (e.UserID == userID || userID == "") {
		delete(lm.locks, k)
	}
}

// CheckWrite returns ok=false and holder info if target is locked by a different user.
func (lm *LockManager) CheckWrite(projectID, kind, id, userID string) (bool, string, string) {
	projectID = normalizeProjectID(projectID)
	lm.mu.Lock()
	defer lm.mu.Unlock()
	k := lockKey(projectID, kind, id)
	e, ok := lm.locks[k]
	if !ok || time.Now().After(e.ExpiresAt) {
		return true, "", ""
	}
	if e.UserID == userID {
		return true, "", ""
	}
	return false, e.UserID, e.UserName
}

// List returns locks; if projectID is empty, returns all projects, otherwise filters.
func (lm *LockManager) List(projectID string) []LockInfo {
	lm.mu.Lock()
	defer lm.mu.Unlock()
	now := time.Now()
	var out []LockInfo
	for k, e := range lm.locks {
		if now.After(e.ExpiresAt) {
			continue
		}
		proj, kind, id := splitLockKey(k)
		if projectID != "" && proj != projectID {
			continue
		}
		out = append(out, LockInfo{
			ProjectID: proj,
			Kind:      kind,
			TargetID:  id,
			UserID:    e.UserID,
			UserName:  e.UserName,
			ExpiresAt: e.ExpiresAt.Unix(),
		})
	}
	return out
}

func (lm *LockManager) gcLoop() {
	t := time.NewTicker(15 * time.Second)
	defer t.Stop()
	for range t.C {
		lm.mu.Lock()
		now := time.Now()
		for k, e := range lm.locks {
			if now.After(e.ExpiresAt) {
				delete(lm.locks, k)
			}
		}
		lm.mu.Unlock()
	}
}

func lockConflictError(kind, id, holderID, holderName string) *rpcError {
	msg := fmt.Sprintf("%s %s is being edited by %s", kind, id, holderName)
	if holderName == "" {
		msg = fmt.Sprintf("%s %s is being edited by %s", kind, id, holderID)
	}
	return &rpcError{Code: "locked", Message: msg}
}
