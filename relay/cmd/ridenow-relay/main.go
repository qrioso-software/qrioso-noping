package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"github.com/qrioso/ridenow-noping/relay/internal/sessionstore"
)

type runtimeHealth struct {
	mu             sync.RWMutex
	snapshotError  error
	sessionCount   int
	snapshotLoaded time.Time
}

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, logger); err != nil {
		logger.Error("relay stopped", "error", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, logger *slog.Logger) error {
	snapshotPath := envOrDefault("RIDENOW_SESSION_FILE", "/run/ridenow-noping/sessions.json")
	tunName := envOrDefault("RIDENOW_TUN_NAME", "ridenow0")
	routeAListen := envOrDefault("RIDENOW_ROUTE_A_LISTEN", "10.78.0.1:51900")
	routeBListen := envOrDefault("RIDENOW_ROUTE_B_LISTEN", "10.79.0.1:51900")
	gaHealthListen := envOrDefault("RIDENOW_GA_HEALTH_LISTEN", "0.0.0.0:8080")
	relayHealthListen := envOrDefault("RIDENOW_RELAY_HEALTH_LISTEN", "127.0.0.1:8082")

	index := newSessionIndex()
	health := &runtimeHealth{}
	if err := reloadSnapshot(snapshotPath, index, health); err != nil {
		return fmt.Errorf("load initial session snapshot: %w", err)
	}
	tun, err := openTUN(tunName)
	if err != nil {
		return err
	}
	routeA, err := listenUDP(routeAListen)
	if err != nil {
		tun.Close()
		return fmt.Errorf("listen route A: %w", err)
	}
	routeB, err := listenUDP(routeBListen)
	if err != nil {
		tun.Close()
		routeA.Close()
		return fmt.Errorf("listen route B: %w", err)
	}

	engine := newRelayEngine(logger, tun, routeA, routeB, index)
	gaServer := &http.Server{
		Addr: gaHealthListen, Handler: gaHealthHandler(health), ReadHeaderTimeout: 2 * time.Second,
		ReadTimeout: 2 * time.Second, WriteTimeout: 2 * time.Second, IdleTimeout: 15 * time.Second,
	}
	relayHealthServer := &http.Server{
		Addr: relayHealthListen, Handler: relayHealthHandler(health, engine), ReadHeaderTimeout: 2 * time.Second,
		ReadTimeout: 2 * time.Second, WriteTimeout: 2 * time.Second, IdleTimeout: 15 * time.Second,
	}
	errorsChannel := make(chan error, 4)
	go func() { errorsChannel <- engine.run(ctx) }()
	go func() { errorsChannel <- watchSnapshots(ctx, logger, snapshotPath, index, health) }()
	go func() {
		logger.Info("Global Accelerator health endpoint listening", "address", gaServer.Addr)
		errorsChannel <- gaServer.ListenAndServe()
	}()
	go func() {
		logger.Info("relay diagnostics endpoint listening", "address", relayHealthServer.Addr)
		errorsChannel <- relayHealthServer.ListenAndServe()
	}()

	logger.Info("multipath relay started", "routeA", routeAListen, "routeB", routeBListen, "tun", tunName)
	select {
	case <-ctx.Done():
	case err := <-errorsChannel:
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			return err
		}
	}
	shutdownContext, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = gaServer.Shutdown(shutdownContext)
	_ = relayHealthServer.Shutdown(shutdownContext)
	return nil
}

func listenUDP(address string) (*net.UDPConn, error) {
	resolved, err := net.ResolveUDPAddr("udp4", address)
	if err != nil {
		return nil, err
	}
	return net.ListenUDP("udp4", resolved)
}

func watchSnapshots(ctx context.Context, logger *slog.Logger, path string, index *sessionIndex, health *runtimeHealth) error {
	ticker := time.NewTicker(250 * time.Millisecond)
	defer ticker.Stop()
	lastError := ""
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-ticker.C:
			err := reloadSnapshot(path, index, health)
			if err != nil {
				index.clear()
				if err.Error() != lastError {
					logger.Error("session snapshot rejected; relay failed closed", "error", err)
					lastError = err.Error()
				}
				continue
			}
			if lastError != "" {
				logger.Info("session snapshot recovered")
				lastError = ""
			}
		}
	}
}

func reloadSnapshot(path string, index *sessionIndex, health *runtimeHealth) error {
	snapshot, err := sessionstore.Load(path)
	if err == nil {
		err = index.replace(snapshot)
	}
	health.mu.Lock()
	health.snapshotError = err
	if err == nil {
		health.sessionCount = len(snapshot.Sessions)
		health.snapshotLoaded = snapshot.GeneratedAt
	}
	health.mu.Unlock()
	return err
}

func relayHealthState(health *runtimeHealth) (int, string) {
	health.mu.RLock()
	snapshotError := health.snapshotError
	loadedAt := health.snapshotLoaded
	health.mu.RUnlock()
	if snapshotError != nil || loadedAt.IsZero() || time.Since(loadedAt) > 5*time.Second || time.Until(loadedAt) > 5*time.Second {
		return http.StatusServiceUnavailable, "unhealthy"
	}
	return http.StatusOK, "healthy"
}

func gaHealthHandler(health *runtimeHealth) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(writer http.ResponseWriter, _ *http.Request) {
		writer.Header().Set("Content-Type", "text/plain; charset=utf-8")
		writer.Header().Set("Cache-Control", "no-store")
		status, state := relayHealthState(health)
		writer.WriteHeader(status)
		_, _ = fmt.Fprintln(writer, state)
	})
	return mux
}

func relayHealthHandler(health *runtimeHealth, engine *relayEngine) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(writer http.ResponseWriter, _ *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		writer.Header().Set("Cache-Control", "no-store")
		health.mu.RLock()
		sessionCount := health.sessionCount
		health.mu.RUnlock()
		status, state := relayHealthState(health)
		writer.WriteHeader(status)
		_ = json.NewEncoder(writer).Encode(map[string]any{
			"status": state, "sessions": sessionCount,
			"uplinkAccepted":   engine.metrics.uplinkAccepted.Load(),
			"uplinkDuplicates": engine.metrics.uplinkDuplicates.Load(),
			"uplinkRejected":   engine.metrics.uplinkRejected.Load(),
			"downlinkPackets":  engine.metrics.downlinkPackets.Load(),
			"downlinkCopies":   engine.metrics.downlinkCopies.Load(),
		})
	})
	return mux
}

func envOrDefault(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}
