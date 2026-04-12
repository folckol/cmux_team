package main

import (
	"fmt"
	"sync"
	"time"
)

// LockManager provides short-lived edit locks on context items.
// Locks expire after TTL unless refreshed via heartbeat. In-memory only.
type LockManager struct {
	mu    sync.Mutex
	locks map[string]*lockEntry // key = kind + ":" + id
	ttl   time.Duration
}

type lockEntry struct {
	UserID    string
	UserName  string
	ExpiresAt time.Time
}

type LockInfo struct {
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

func lockKey(kind, id string) string { return kind + ":" + id }

// Acquire returns (ok, holderUserID, holderName). If already locked by another user, ok=false.
// If already locked by same user, it refreshes TTL.
func (lm *LockManager) Acquire(kind, id, userID, userName string) (bool, string, string) {
	lm.mu.Lock()
	defer lm.mu.Unlock()
	k := lockKey(kind, id)
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
func (lm *LockManager) Heartbeat(kind, id, userID string) bool {
	lm.mu.Lock()
	defer lm.mu.Unlock()
	k := lockKey(kind, id)
	e, ok := lm.locks[k]
	if !ok || e.UserID != userID {
		return false
	}
	e.ExpiresAt = time.Now().Add(lm.ttl)
	return true
}

func (lm *LockManager) Release(kind, id, userID string) {
	lm.mu.Lock()
	defer lm.mu.Unlock()
	k := lockKey(kind, id)
	if e, ok := lm.locks[k]; ok && (e.UserID == userID || userID == "") {
		delete(lm.locks, k)
	}
}

// CheckWrite returns ok=false and holder info if target is locked by a different user.
func (lm *LockManager) CheckWrite(kind, id, userID string) (bool, string, string) {
	lm.mu.Lock()
	defer lm.mu.Unlock()
	k := lockKey(kind, id)
	e, ok := lm.locks[k]
	if !ok || time.Now().After(e.ExpiresAt) {
		return true, "", ""
	}
	if e.UserID == userID {
		return true, "", ""
	}
	return false, e.UserID, e.UserName
}

func (lm *LockManager) List() []LockInfo {
	lm.mu.Lock()
	defer lm.mu.Unlock()
	now := time.Now()
	var out []LockInfo
	for k, e := range lm.locks {
		if now.After(e.ExpiresAt) {
			continue
		}
		kind, id := splitLockKey(k)
		out = append(out, LockInfo{
			Kind:      kind,
			TargetID:  id,
			UserID:    e.UserID,
			UserName:  e.UserName,
			ExpiresAt: e.ExpiresAt.Unix(),
		})
	}
	return out
}

func splitLockKey(k string) (string, string) {
	for i := 0; i < len(k); i++ {
		if k[i] == ':' {
			return k[:i], k[i+1:]
		}
	}
	return k, ""
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
