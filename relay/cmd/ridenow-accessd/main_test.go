package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/qrioso/ridenow-noping/relay/internal/access"
)

type fakePeerController struct {
	applied []deviceLease
	removed []deviceLease
	reset   bool
	err     error
}

func (controller *fakePeerController) Apply(_ context.Context, lease deviceLease) error {
	controller.applied = append(controller.applied, lease)
	return controller.err
}

func (controller *fakePeerController) Remove(_ context.Context, lease deviceLease) error {
	controller.removed = append(controller.removed, lease)
	return controller.err
}

func (controller *fakePeerController) Reset(context.Context) error {
	controller.reset = true
	return controller.err
}

func TestSessionRejectsInvalidPeerKeys(t *testing.T) {
	handler, token := testSessionHandler(t, 1, 10*time.Second)
	request := sessionRequest{
		Token: token, DeviceID: "pc-uno", PublicKeyA: "not-a-wireguard-key", PublicKeyB: testPublicKey(2),
	}
	response := performSessionRequest(t, handler, request)
	if response.Code != http.StatusBadRequest || !strings.Contains(response.Body.String(), "invalid_peer_keys") {
		t.Fatalf("unexpected response: %d %s", response.Code, response.Body.String())
	}
}

func TestSessionRejectsSamePeerKeyForBothRoutes(t *testing.T) {
	handler, token := testSessionHandler(t, 1, 10*time.Second)
	key := testPublicKey(1)
	response := performSessionRequest(t, handler, sessionRequest{
		Token: token, DeviceID: "pc-uno", PublicKeyA: key, PublicKeyB: key,
	})
	if response.Code != http.StatusBadRequest {
		t.Fatalf("unexpected response: %d %s", response.Code, response.Body.String())
	}
}

func TestSessionRejectsInvalidDeviceIDAndAllZeroPeer(t *testing.T) {
	handler, token := testSessionHandler(t, 1, 10*time.Second)
	response := performSessionRequest(t, handler, sessionRequest{
		Token: token, DeviceID: "x", PublicKeyA: testPublicKey(1), PublicKeyB: testPublicKey(2),
	})
	if response.Code != http.StatusBadRequest || !strings.Contains(response.Body.String(), "invalid_device_id") {
		t.Fatalf("invalid device ID accepted: %d %s", response.Code, response.Body.String())
	}
	response = performSessionRequest(t, handler, sessionRequest{
		Token: token, DeviceID: "pc-uno", PublicKeyA: testPublicKey(0), PublicKeyB: testPublicKey(2),
	})
	if response.Code != http.StatusBadRequest || !strings.Contains(response.Body.String(), "invalid_peer_keys") {
		t.Fatalf("all-zero public key accepted: %d %s", response.Code, response.Body.String())
	}
}

func TestSessionEnforcesMaxDevicesByPeerKeys(t *testing.T) {
	handler, token := testSessionHandler(t, 1, 10*time.Second)
	first := sessionRequest{
		Token: token, DeviceID: "pc-uno", PublicKeyA: testPublicKey(1), PublicKeyB: testPublicKey(2),
	}
	if response := performSessionRequest(t, handler, first); response.Code != http.StatusOK {
		t.Fatalf("first device denied: %d %s", response.Code, response.Body.String())
	}
	first.DeviceID = "nombre-distinto"
	if response := performSessionRequest(t, handler, first); response.Code != http.StatusOK {
		t.Fatalf("same peer pair should renew its slot: %d %s", response.Code, response.Body.String())
	}
	second := sessionRequest{
		Token: token, DeviceID: "pc-dos", PublicKeyA: testPublicKey(3), PublicKeyB: testPublicKey(4),
	}
	response := performSessionRequest(t, handler, second)
	if response.Code != http.StatusForbidden || !strings.Contains(response.Body.String(), "device_limit_reached") {
		t.Fatalf("second peer pair bypassed maxDevices: %d %s", response.Code, response.Body.String())
	}
}

func TestSessionReturnsConfiguredEndpoints(t *testing.T) {
	handler, token := testSessionHandler(t, 1, 10*time.Second)
	response := performSessionRequest(t, handler, sessionRequest{
		Token: token, DeviceID: "pc-uno", PublicKeyA: testPublicKey(1), PublicKeyB: testPublicKey(2),
	})
	if response.Code != http.StatusOK {
		t.Fatalf("unexpected response: %d %s", response.Code, response.Body.String())
	}
	var body sessionResponse
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body.DirectEndpoint != "203.0.113.10:51820" || body.AcceleratedEndpoint != "a123.awsglobalaccelerator.com:51821" || body.LeaseSeconds != 10 {
		t.Fatalf("unexpected session response: %+v", body)
	}
}

func TestEndpointConfigurationFailsClosed(t *testing.T) {
	tests := []struct {
		direct      string
		accelerated string
	}{
		{"", "a123.awsglobalaccelerator.com:51821"},
		{"203.0.113.10:51821", "a123.awsglobalaccelerator.com:51821"},
		{"203.0.113.10:51820", ""},
		{"203.0.113.10:51820", "a123.awsglobalaccelerator.com:51820"},
		{"relay.example.test:51820", "a123.awsglobalaccelerator.com:51821"},
		{"10.0.0.10:51820", "a123.awsglobalaccelerator.com:51821"},
		{"203.0.113.10:51820", "bad..host:51821"},
		{"203.0.113.10:51820", "ga.example.test:51821"},
		{" 203.0.113.10:51820", "a123.awsglobalaccelerator.com:51821"},
	}
	for _, test := range tests {
		if _, err := newEndpointConfig(test.direct, test.accelerated); err == nil {
			t.Fatalf("expected endpoints to be rejected: %#v", test)
		}
	}
}

func TestRunRejectsInvalidAccessFileBeforeServing(t *testing.T) {
	path := filepath.Join(t.TempDir(), "access-keys.yaml")
	if err := os.WriteFile(path, []byte("version: 1\nkeys:\n  broken: true\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	t.Setenv("RIDENOW_ACCESS_FILE", path)
	t.Setenv("RIDENOW_TLS_CERT", "/not-used/tls.crt")
	t.Setenv("RIDENOW_TLS_KEY", "/not-used/tls.key")
	t.Setenv("RIDENOW_DIRECT_ENDPOINT", "203.0.113.10:51820")
	t.Setenv("RIDENOW_ACCELERATED_ENDPOINT", "a123.awsglobalaccelerator.com:51821")
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	if err := run(logger); err == nil || !strings.Contains(err.Error(), "refusing to start") {
		t.Fatalf("invalid access file did not fail startup: %v", err)
	}
}

func TestHealthFailsClosedAfterAccessFileBecomesInvalid(t *testing.T) {
	path := filepath.Join(t.TempDir(), "access-keys.yaml")
	if err := access.WriteAtomic(path, access.EmptyDocument()); err != nil {
		t.Fatal(err)
	}
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	coordinator := newSessionCoordinator(newLeaseRegistry(10*time.Second, 10), &fakePeerController{}, filepath.Join(t.TempDir(), "sessions.json"))
	if err := coordinator.initialize(context.Background(), time.Now()); err != nil {
		t.Fatal(err)
	}
	handler := healthHandler(logger, path, coordinator)
	request := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("valid access file reported unhealthy: %d", response.Code)
	}
	if err := os.WriteFile(path, []byte("not: valid: yaml\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	response = httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("invalid access file reported healthy: %d", response.Code)
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	response = httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("missing access file reported healthy: %d", response.Code)
	}
}

func TestLeaseRegistryReleasesExpiredDeviceSlot(t *testing.T) {
	registry := newLeaseRegistry(10*time.Second, 10)
	now := time.Unix(100, 0)
	if !registry.grant("cliente-001", "pc-uno", "fingerprint-a", 1, now) {
		t.Fatal("first device should be admitted")
	}
	if registry.grant("cliente-001", "pc-dos", "fingerprint-b", 1, now.Add(9*time.Second)) {
		t.Fatal("second device should be blocked while the first lease is active")
	}
	if !registry.grant("cliente-001", "pc-dos", "fingerprint-b", 1, now.Add(10*time.Second)) {
		t.Fatal("expired device slot was not released")
	}
}

func TestLeaseRegistryConvergesWhenPerKeyLimitDrops(t *testing.T) {
	registry := newLeaseRegistry(10*time.Second, 10)
	now := time.Unix(100, 0)
	for index := 0; index < 3; index++ {
		if !registry.grant("cliente-001", "pc", fmt.Sprintf("fingerprint-%d", index), 3, now) {
			t.Fatalf("device %d should be admitted at the original limit", index)
		}
	}
	for index := 0; index < 3; index++ {
		if registry.grant("cliente-001", "pc", fmt.Sprintf("fingerprint-%d", index), 1, now.Add(time.Second)) {
			t.Fatalf("excess device %d had its lease extended after the limit dropped", index)
		}
	}
	if !registry.grant("cliente-001", "pc", "fingerprint-0", 1, now.Add(10*time.Second)) {
		t.Fatal("one device should be admitted after the excess leases expire")
	}
	if registry.grant("cliente-001", "pc", "fingerprint-1", 1, now.Add(10*time.Second)) {
		t.Fatal("a second device bypassed the reduced per-key limit")
	}
}

func TestLeaseRegistryEnforcesGlobalClientLimitAcrossKeys(t *testing.T) {
	registry := newLeaseRegistry(10*time.Second, 10)
	now := time.Unix(100, 0)
	for index := 0; index < 10; index++ {
		if !registry.grant("cliente-a", "pc", fmt.Sprintf("fingerprint-a-%d", index), 10, now) {
			t.Fatalf("global slot %d should be admitted", index)
		}
	}
	if registry.grant("cliente-b", "pc", "fingerprint-b", 10, now) {
		t.Fatal("an eleventh client bypassed the global limit through another key")
	}
	if !registry.grant("cliente-a", "pc", "fingerprint-a-0", 10, now.Add(time.Second)) {
		t.Fatal("an existing client should still be able to renew at the global limit")
	}
}

func TestMaxClientsEnvironmentFailsClosed(t *testing.T) {
	for _, value := range []string{"0", "11", "not-a-number", " 10"} {
		t.Run(value, func(t *testing.T) {
			t.Setenv("RIDENOW_MAX_CLIENTS", value)
			if _, err := maxClientsFromEnvironment(); err == nil {
				t.Fatalf("invalid RIDENOW_MAX_CLIENTS %q was accepted", value)
			}
		})
	}
	t.Setenv("RIDENOW_MAX_CLIENTS", "10")
	if value, err := maxClientsFromEnvironment(); err != nil || value != 10 {
		t.Fatalf("valid RIDENOW_MAX_CLIENTS rejected: value=%d err=%v", value, err)
	}
}

func TestAccessRateLimiterRejectsRequestsBeyondPerClientWindow(t *testing.T) {
	limiter := newAccessRateLimiter()
	nextCalls := 0
	handler := limiter.wrap(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		nextCalls++
		writer.WriteHeader(http.StatusNoContent)
	}))

	for requestNumber := 1; requestNumber <= 31; requestNumber++ {
		request := httptest.NewRequest(http.MethodPost, "https://relay.example/v1/session", nil)
		request.RemoteAddr = "198.51.100.10:45000"
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		if requestNumber <= 30 && response.Code != http.StatusNoContent {
			t.Fatalf("request %d was rejected with status %d", requestNumber, response.Code)
		}
		if requestNumber == 31 && response.Code != http.StatusTooManyRequests {
			t.Fatalf("request beyond limit returned %d", response.Code)
		}
	}
	if nextCalls != 30 {
		t.Fatalf("downstream handler called %d times", nextCalls)
	}
}

func TestAccessRateLimiterPrunesStaleClientsBeforeCapacityCheck(t *testing.T) {
	limiter := newAccessRateLimiter()
	stale := time.Now().Add(-3 * time.Minute)
	for index := 0; index < 4096; index++ {
		limiter.clients[fmt.Sprintf("198.51.%d.%d", index/256, index%256)] = accessRateEntry{
			windowStart: stale,
			lastSeen:    stale,
			requests:    1,
		}
	}

	handler := limiter.wrap(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		writer.WriteHeader(http.StatusNoContent)
	}))
	request := httptest.NewRequest(http.MethodPost, "https://relay.example/v1/session", nil)
	request.RemoteAddr = "203.0.113.25:45000"
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusNoContent {
		t.Fatalf("new client was rejected after stale entries should have been pruned: %d", response.Code)
	}
	if len(limiter.clients) != 1 {
		t.Fatalf("rate limiter retained %d clients after pruning", len(limiter.clients))
	}
}

func testSessionHandler(t *testing.T, maxDevices int, leaseDuration time.Duration) (http.Handler, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "access-keys.yaml")
	token, err := access.GenerateToken("cliente-001")
	if err != nil {
		t.Fatal(err)
	}
	document := access.EmptyDocument()
	if err := access.Add(&document, "cliente-001", token, maxDevices, "test"); err != nil {
		t.Fatal(err)
	}
	if err := access.WriteAtomic(path, document); err != nil {
		t.Fatal(err)
	}
	endpoints, err := newEndpointConfig("203.0.113.10:51820", "a123.awsglobalaccelerator.com:51821")
	if err != nil {
		t.Fatal(err)
	}
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	coordinator := newSessionCoordinator(newLeaseRegistry(leaseDuration, 10), &fakePeerController{}, filepath.Join(t.TempDir(), "sessions.json"))
	if err := coordinator.initialize(context.Background(), time.Now()); err != nil {
		t.Fatal(err)
	}
	return sessionHandler(logger, path, endpoints, testPublicKey(9), testPublicKey(10), coordinator), token
}

func performSessionRequest(t *testing.T, handler http.Handler, body sessionRequest) *httptest.ResponseRecorder {
	t.Helper()
	encoded, err := json.Marshal(body)
	if err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(http.MethodPost, "/v1/session", bytes.NewReader(encoded))
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	return response
}

func testPublicKey(fill byte) string {
	return base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{fill}, 32))
}
