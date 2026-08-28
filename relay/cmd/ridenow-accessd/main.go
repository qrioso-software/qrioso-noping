package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/fsnotify/fsnotify"
	"github.com/qrioso/ridenow-noping/relay/internal/access"
)

type sessionRequest struct {
	Token      string `json:"token"`
	DeviceID   string `json:"deviceId"`
	PublicKeyA string `json:"publicKeyA"`
	PublicKeyB string `json:"publicKeyB"`
}

type sessionResponse struct {
	Status              string `json:"status"`
	LeaseSeconds        int    `json:"leaseSeconds"`
	DirectEndpoint      string `json:"directEndpoint"`
	AcceleratedEndpoint string `json:"acceleratedEndpoint"`
	ServerPublicKeyA    string `json:"serverPublicKeyA"`
	ServerPublicKeyB    string `json:"serverPublicKeyB"`
	ClientAddressA      string `json:"clientAddressA"`
	ClientAddressB      string `json:"clientAddressB"`
	VirtualAddress      string `json:"virtualAddress"`
	RelayDataAddressA   string `json:"relayDataAddressA"`
	RelayDataAddressB   string `json:"relayDataAddressB"`
	SessionID           string `json:"sessionId"`
	MTU                 int    `json:"mtu"`
}

type endpointConfig struct {
	direct      string
	accelerated string
}

type accessRateEntry struct {
	windowStart time.Time
	lastSeen    time.Time
	requests    int
}

type accessRateLimiter struct {
	mu      sync.Mutex
	clients map[string]accessRateEntry
	slots   chan struct{}
}

func newAccessRateLimiter() *accessRateLimiter {
	return &accessRateLimiter{clients: make(map[string]accessRateEntry), slots: make(chan struct{}, 32)}
}

var deviceIDPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{2,127}$`)
var dnsNamePattern = regexp.MustCompile(`^[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$`)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	if err := run(logger); err != nil {
		logger.Error("access service stopped", "error", err)
		os.Exit(1)
	}
}

func run(logger *slog.Logger) error {
	accessFile := envOrDefault("RIDENOW_ACCESS_FILE", "/etc/ridenow-noping/access-keys.yaml")
	tlsCertificate := os.Getenv("RIDENOW_TLS_CERT")
	tlsKey := os.Getenv("RIDENOW_TLS_KEY")
	if tlsCertificate == "" || tlsKey == "" {
		return errors.New("RIDENOW_TLS_CERT and RIDENOW_TLS_KEY are required")
	}
	endpoints, err := newEndpointConfig(os.Getenv("RIDENOW_DIRECT_ENDPOINT"), os.Getenv("RIDENOW_ACCELERATED_ENDPOINT"))
	if err != nil {
		return fmt.Errorf("route endpoints are invalid: %w", err)
	}
	if _, err := access.LoadExisting(accessFile); err != nil {
		return fmt.Errorf("access file is invalid; refusing to start: %w", err)
	}
	serverPublicKeyA := os.Getenv("RIDENOW_WG_PUBLIC_KEY_A")
	serverPublicKeyB := os.Getenv("RIDENOW_WG_PUBLIC_KEY_B")
	if _, err := peerFingerprint(serverPublicKeyA, serverPublicKeyB); err != nil {
		return fmt.Errorf("WireGuard server public keys are invalid: %w", err)
	}
	maxClients, err := maxClientsFromEnvironment()
	if err != nil {
		return err
	}
	registry := newLeaseRegistry(10*time.Second, maxClients)
	peerManager, err := newWireGuardPeerController(
		envOrDefault("RIDENOW_WG_COMMAND", "/usr/bin/wg"),
		envOrDefault("RIDENOW_WG_INTERFACE_A", "wg-direct"),
		envOrDefault("RIDENOW_WG_INTERFACE_B", "wg-accelerated"),
	)
	if err != nil {
		return err
	}
	coordinator := newSessionCoordinator(registry, peerManager, envOrDefault("RIDENOW_SESSION_FILE", "/run/ridenow-noping/sessions.json"))
	if err := coordinator.initialize(context.Background(), time.Now()); err != nil {
		return err
	}

	apiMux := http.NewServeMux()
	apiMux.HandleFunc("POST /v1/session", sessionHandler(logger, accessFile, endpoints, serverPublicKeyA, serverPublicKeyB, coordinator))
	apiHandler := newAccessRateLimiter().wrap(apiMux)
	apiServer := &http.Server{
		Addr:              envOrDefault("RIDENOW_ACCESS_LISTEN", ":8443"),
		Handler:           apiHandler,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       5 * time.Second,
		WriteTimeout:      5 * time.Second,
		IdleTimeout:       30 * time.Second,
		MaxHeaderBytes:    16 * 1024,
		TLSConfig:         &tls.Config{MinVersion: tls.VersionTLS12},
	}

	healthMux := http.NewServeMux()
	healthMux.Handle("GET /healthz", healthHandler(logger, accessFile, coordinator))
	healthServer := &http.Server{
		Addr:              envOrDefault("RIDENOW_HEALTH_LISTEN", ":8080"),
		Handler:           healthMux,
		ReadHeaderTimeout: 2 * time.Second,
		ReadTimeout:       2 * time.Second,
		WriteTimeout:      2 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	errorsChannel := make(chan error, 3)
	go func() {
		logger.Info("access API listening", "address", apiServer.Addr)
		errorsChannel <- apiServer.ListenAndServeTLS(tlsCertificate, tlsKey)
	}()
	go func() {
		errorsChannel <- watchAccessFile(ctx, logger, accessFile, coordinator)
	}()
	go func() {
		logger.Info("health endpoint listening", "address", healthServer.Addr)
		errorsChannel <- healthServer.ListenAndServe()
	}()

	var serverError error
	select {
	case <-ctx.Done():
	case err := <-errorsChannel:
		if !errors.Is(err, http.ErrServerClosed) {
			serverError = fmt.Errorf("server stopped unexpectedly: %w", err)
		} else if ctx.Err() == nil {
			serverError = errors.New("server stopped unexpectedly")
		}
	}

	shutdownContext, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	apiShutdownError := apiServer.Shutdown(shutdownContext)
	healthShutdownError := healthServer.Shutdown(shutdownContext)
	if serverError != nil {
		return serverError
	}
	if apiShutdownError != nil {
		return fmt.Errorf("shutdown access API: %w", apiShutdownError)
	}
	if healthShutdownError != nil {
		return fmt.Errorf("shutdown health API: %w", healthShutdownError)
	}
	return nil
}

func (limiter *accessRateLimiter) wrap(next http.Handler) http.Handler {
	return http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		select {
		case limiter.slots <- struct{}{}:
			defer func() { <-limiter.slots }()
		default:
			writer.Header().Set("Retry-After", "2")
			writeJSON(writer, http.StatusServiceUnavailable, map[string]string{"error": "server_busy"})
			return
		}

		host, _, err := net.SplitHostPort(request.RemoteAddr)
		if err != nil {
			writeJSON(writer, http.StatusBadRequest, map[string]string{"error": "invalid_remote"})
			return
		}
		now := time.Now()
		limiter.mu.Lock()
		if len(limiter.clients) > 1024 {
			for candidate, candidateEntry := range limiter.clients {
				if now.Sub(candidateEntry.lastSeen) > 2*time.Minute {
					delete(limiter.clients, candidate)
				}
			}
		}
		entry, knownClient := limiter.clients[host]
		if !knownClient && len(limiter.clients) >= 4096 {
			limiter.mu.Unlock()
			writer.Header().Set("Retry-After", "60")
			writeJSON(writer, http.StatusTooManyRequests, map[string]string{"error": "rate_limited"})
			return
		}
		if entry.windowStart.IsZero() || now.Sub(entry.windowStart) >= time.Minute {
			entry.windowStart = now
			entry.requests = 0
		}
		entry.requests++
		entry.lastSeen = now
		limiter.clients[host] = entry
		allowed := entry.requests <= 30
		limiter.mu.Unlock()
		if !allowed {
			writer.Header().Set("Retry-After", "60")
			writeJSON(writer, http.StatusTooManyRequests, map[string]string{"error": "rate_limited"})
			return
		}
		next.ServeHTTP(writer, request)
	})
}

func healthHandler(logger *slog.Logger, accessFile string, coordinator *sessionCoordinator) http.Handler {
	return http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		writer.Header().Set("Content-Type", "text/plain; charset=utf-8")
		writer.Header().Set("Cache-Control", "no-store")
		if _, err := access.LoadExisting(accessFile); err != nil {
			logger.Error("health check rejected invalid access file", "error", err)
			writer.WriteHeader(http.StatusServiceUnavailable)
			_, _ = writer.Write([]byte("unhealthy\n"))
			return
		}
		if err := coordinator.healthy(); err != nil {
			logger.Error("health check rejected peer reconciliation state", "error", err)
			writer.WriteHeader(http.StatusServiceUnavailable)
			_, _ = writer.Write([]byte("unhealthy\n"))
			return
		}
		writer.WriteHeader(http.StatusOK)
		_, _ = writer.Write([]byte("ok\n"))
	})
}

func sessionHandler(logger *slog.Logger, accessFile string, endpoints endpointConfig, serverPublicKeyA, serverPublicKeyB string, coordinator *sessionCoordinator) http.HandlerFunc {
	return func(writer http.ResponseWriter, request *http.Request) {
		request.Body = http.MaxBytesReader(writer, request.Body, 32*1024)
		decoder := json.NewDecoder(request.Body)
		decoder.DisallowUnknownFields()
		var body sessionRequest
		if err := decoder.Decode(&body); err != nil {
			writeJSON(writer, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
			return
		}
		if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
			writeJSON(writer, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
			return
		}
		if !deviceIDPattern.MatchString(body.DeviceID) {
			writeJSON(writer, http.StatusBadRequest, map[string]string{"error": "invalid_device_id"})
			return
		}
		fingerprint, err := peerFingerprint(body.PublicKeyA, body.PublicKeyB)
		if err != nil {
			writeJSON(writer, http.StatusBadRequest, map[string]string{"error": "invalid_peer_keys"})
			return
		}

		document, err := access.LoadExisting(accessFile)
		if err != nil {
			logger.Error("access file rejected; failing closed", "error", err)
			writeJSON(writer, http.StatusServiceUnavailable, map[string]string{"error": "authorization_unavailable"})
			return
		}
		id, entry, authorized := access.Authorize(document, body.Token)
		if !authorized {
			logger.Warn("access denied", "deviceId", body.DeviceID)
			writeJSON(writer, http.StatusUnauthorized, map[string]string{"error": "access_denied"})
			return
		}
		lease, granted, err := coordinator.grant(request.Context(), id, body.DeviceID, fingerprint, body.PublicKeyA, body.PublicKeyB, entry.MaxDevices, time.Now())
		if err != nil {
			logger.Error("session provisioning failed", "keyId", id, "deviceId", body.DeviceID, "error", err)
			writeJSON(writer, http.StatusServiceUnavailable, map[string]string{"error": "provisioning_unavailable"})
			return
		}
		if !granted {
			logger.Warn("device limit reached", "keyId", id, "deviceId", body.DeviceID)
			writeJSON(writer, http.StatusForbidden, map[string]string{"error": "device_limit_reached"})
			return
		}

		logger.Info("access granted", "keyId", id, "deviceId", body.DeviceID)
		writeJSON(writer, http.StatusOK, sessionResponse{
			Status:              "authorized",
			LeaseSeconds:        int(coordinator.registry.duration / time.Second),
			DirectEndpoint:      endpoints.direct,
			AcceleratedEndpoint: endpoints.accelerated,
			ServerPublicKeyA:    serverPublicKeyA,
			ServerPublicKeyB:    serverPublicKeyB,
			ClientAddressA:      lease.clientAddressA + "/32",
			ClientAddressB:      lease.clientAddressB + "/32",
			VirtualAddress:      lease.virtualAddress + "/32",
			RelayDataAddressA:   "10.78.0.1:51900",
			RelayDataAddressB:   "10.79.0.1:51900",
			SessionID:           lease.sessionID,
			MTU:                 1420,
		})
	}
}

func watchAccessFile(ctx context.Context, logger *slog.Logger, accessFile string, coordinator *sessionCoordinator) error {
	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		return fmt.Errorf("create access-file watcher: %w", err)
	}
	defer watcher.Close()
	if err := watcher.Add(filepath.Dir(accessFile)); err != nil {
		return fmt.Errorf("watch access-file directory: %w", err)
	}
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	reconcile := func() {
		document, loadError := access.LoadExisting(accessFile)
		if loadError != nil {
			logger.Error("access file invalid; refusing renewals and expiring leases", "error", loadError)
			if expireError := coordinator.expireOnly(ctx, time.Now()); expireError != nil {
				logger.Error("expire leases after invalid access file", "error", expireError)
			}
			return
		}
		if reconcileError := coordinator.reconcile(ctx, document, time.Now()); reconcileError != nil {
			logger.Error("reconcile access leases", "error", reconcileError)
		}
	}
	for {
		select {
		case <-ctx.Done():
			return nil
		case watcherError, ok := <-watcher.Errors:
			if !ok {
				return errors.New("access-file watcher closed unexpectedly")
			}
			logger.Error("access-file watcher error", "error", watcherError)
		case event, ok := <-watcher.Events:
			if !ok {
				return errors.New("access-file watcher closed unexpectedly")
			}
			if filepath.Clean(event.Name) == filepath.Clean(accessFile) {
				reconcile()
			}
		case <-ticker.C:
			reconcile()
		}
	}
}

func newEndpointConfig(direct, accelerated string) (endpointConfig, error) {
	if err := validateEndpoint(direct, 51820, true); err != nil {
		return endpointConfig{}, fmt.Errorf("RIDENOW_DIRECT_ENDPOINT: %w", err)
	}
	if err := validateEndpoint(accelerated, 51821, false); err != nil {
		return endpointConfig{}, fmt.Errorf("RIDENOW_ACCELERATED_ENDPOINT: %w", err)
	}
	return endpointConfig{direct: direct, accelerated: accelerated}, nil
}

func validateEndpoint(endpoint string, expectedPort int, requireIPv4 bool) error {
	if endpoint != strings.TrimSpace(endpoint) {
		return errors.New("must not contain surrounding whitespace")
	}
	host, portValue, err := net.SplitHostPort(endpoint)
	if err != nil || strings.TrimSpace(host) == "" {
		return errors.New("must be a non-empty host:port endpoint")
	}
	port, err := strconv.Atoi(portValue)
	if err != nil || port != expectedPort {
		return fmt.Errorf("must use UDP port %d", expectedPort)
	}
	parsedIP := net.ParseIP(host)
	if requireIPv4 && (parsedIP == nil || parsedIP.To4() == nil) {
		return errors.New("must use the relay Elastic IPv4 address")
	}
	if requireIPv4 && (!parsedIP.IsGlobalUnicast() || parsedIP.IsPrivate() || parsedIP.IsLoopback() || parsedIP.IsUnspecified()) {
		return errors.New("must use a public relay Elastic IPv4 address")
	}
	if !requireIPv4 && parsedIP != nil {
		return errors.New("must use the Global Accelerator DNS name")
	}
	if !requireIPv4 {
		if !dnsNamePattern.MatchString(host) || strings.Contains(host, "..") {
			return errors.New("must use a valid DNS name or IP address")
		}
		for _, label := range strings.Split(host, ".") {
			if strings.HasPrefix(label, "-") || strings.HasSuffix(label, "-") || len(label) > 63 {
				return errors.New("must use a valid DNS name or IP address")
			}
		}
		if !strings.HasSuffix(strings.ToLower(host), ".awsglobalaccelerator.com") {
			return errors.New("must use the Global Accelerator DNS name")
		}
	}
	return nil
}

func writeJSON(writer http.ResponseWriter, status int, body any) {
	writer.Header().Set("Content-Type", "application/json")
	writer.Header().Set("Cache-Control", "no-store")
	writer.WriteHeader(status)
	if err := json.NewEncoder(writer).Encode(body); err != nil {
		fmt.Fprintln(os.Stderr, "encode response:", err)
	}
}

func envOrDefault(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}

func maxClientsFromEnvironment() (int, error) {
	value := envOrDefault("RIDENOW_MAX_CLIENTS", "10")
	maxClients, err := strconv.Atoi(value)
	if err != nil || maxClients < 1 || maxClients > 10 {
		return 0, errors.New("RIDENOW_MAX_CLIENTS must be an integer between 1 and 10")
	}
	return maxClients, nil
}
