package node

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/ethereum/go-ethereum/common"
)

// loadOrGenerateJWT loads the JWT secret from file or generates a new one.
func (n *Node) loadOrGenerateJWT(path string) ([]byte, error) {
	// Check if file exists
	if _, err := os.Stat(path); os.IsNotExist(err) {
		// Generate
		secret := make([]byte, 32)
		if _, err := rand.Read(secret); err != nil {
			return nil, err
		}
		hexSecret := common.Bytes2Hex(secret)
		if err := os.WriteFile(path, []byte(hexSecret), 0600); err != nil {
			return nil, err
		}
		return secret, nil
	}
	// Read
	content, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	trimmed := strings.TrimSpace(string(content))
	return common.Hex2Bytes(trimmed), nil
}

// validateJWT validates a token against the secret using HMAC-SHA256.
func (n *Node) validateJWT(tokenString string, secret []byte) bool {
	parts := strings.Split(tokenString, ".")
	if len(parts) != 3 {
		return false
	}

	// 1. Signature Check
	// Input for signature is "Header.Payload"
	msg := parts[0] + "." + parts[1]

	// Decode provided signature (Base64Url)
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		// Try standard encoding if raw failed, though JWT uses RawURL
		sig, err = base64.URLEncoding.DecodeString(parts[2])
		if err != nil {
			return false
		}
	}

	// Compute expected signature
	mac := hmac.New(sha256.New, secret)
	mac.Write([]byte(msg))
	expectedSig := mac.Sum(nil)

	if !hmac.Equal(sig, expectedSig) {
		return false
	}

	// 2. Claims Check (Optional but recommended: Expiration/IssuedAt)
	payloadBytes, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		payloadBytes, err = base64.URLEncoding.DecodeString(parts[1])
		if err != nil {
			return false
		}
	}

	var claims map[string]interface{}
	if err := json.Unmarshal(payloadBytes, &claims); err != nil {
		return false
	}

	// Check 'iat' (Issued At) - Optional strictness
	if iatVal, ok := claims["iat"]; ok {
		// handle float64 (JSON default number)
		var iat int64
		switch v := iatVal.(type) {
		case float64:
			iat = int64(v)
		case int64:
			iat = v
		}

		now := time.Now().Unix()
		// Allow 60 seconds drift
		if iat > now+60 || iat < now-60 {
			// Too far in future or past
			return false
		}
	}

	return true
}

// RateLimiter implements a simple fixed-window rate limiter.
type RateLimiter struct {
	limit    int
	window   time.Duration
	visitors map[string]*visitor
	mu       sync.Mutex
}

type visitor struct {
	lastSeen time.Time
	count    int
}

func NewRateLimiter(limit int, window time.Duration) *RateLimiter {
	rl := &RateLimiter{
		limit:    limit,
		window:   window,
		visitors: make(map[string]*visitor),
	}
	// Cleanup loop
	go func() {
		for {
			time.Sleep(window * 2)
			rl.cleanup()
		}
	}()
	return rl
}

func (rl *RateLimiter) cleanup() {
	rl.mu.Lock()
	defer rl.mu.Unlock()
	now := time.Now()
	for ip, v := range rl.visitors {
		if now.Sub(v.lastSeen) > rl.window*2 {
			delete(rl.visitors, ip)
		}
	}
}

func (rl *RateLimiter) Middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ip, _, err := net.SplitHostPort(r.RemoteAddr)
		if err != nil {
			ip = r.RemoteAddr
		}

		rl.mu.Lock()
		v, exists := rl.visitors[ip]
		if !exists {
			rl.visitors[ip] = &visitor{lastSeen: time.Now(), count: 1}
			rl.mu.Unlock()
			next.ServeHTTP(w, r)
			return
		}

		// Reset window if passed
		if time.Since(v.lastSeen) > rl.window {
			v.lastSeen = time.Now()
			v.count = 0
		}

		v.count++

		if v.count > rl.limit {
			rl.mu.Unlock()
			http.Error(w, "429 Too Many Requests", http.StatusTooManyRequests)
			return
		}
		rl.mu.Unlock()

		next.ServeHTTP(w, r)
	})
}
