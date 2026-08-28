package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestGAHealthDoesNotExposeRelayDiagnostics(t *testing.T) {
	health := &runtimeHealth{sessionCount: 7, snapshotLoaded: time.Now()}
	request := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	response := httptest.NewRecorder()

	gaHealthHandler(health).ServeHTTP(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusOK)
	}
	body := response.Body.String()
	if body != "healthy\n" {
		t.Fatalf("body = %q, want only public health state", body)
	}
	if strings.Contains(body, "session") || strings.Contains(body, "packet") || strings.Contains(body, "copies") {
		t.Fatalf("public health response exposed relay diagnostics: %q", body)
	}
}

func TestGAHealthFailsClosedForStaleSnapshot(t *testing.T) {
	health := &runtimeHealth{sessionCount: 7, snapshotLoaded: time.Now().Add(-6 * time.Second)}
	request := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	response := httptest.NewRecorder()

	gaHealthHandler(health).ServeHTTP(response, request)

	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusServiceUnavailable)
	}
	if response.Body.String() != "unhealthy\n" {
		t.Fatalf("body = %q, want only public health state", response.Body.String())
	}
}
