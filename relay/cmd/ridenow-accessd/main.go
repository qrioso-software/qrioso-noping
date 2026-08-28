package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

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
}

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	accessFile := envOrDefault("RIDENOW_ACCESS_FILE", "/etc/ridenow-noping/access-keys.yaml")
	tlsCertificate := os.Getenv("RIDENOW_TLS_CERT")
	tlsKey := os.Getenv("RIDENOW_TLS_KEY")
	if tlsCertificate == "" || tlsKey == "" {
		logger.Error("RIDENOW_TLS_CERT and RIDENOW_TLS_KEY are required")
		os.Exit(1)
	}

	apiMux := http.NewServeMux()
	apiMux.HandleFunc("POST /v1/session", sessionHandler(logger, accessFile))
	apiServer := &http.Server{
		Addr:              envOrDefault("RIDENOW_ACCESS_LISTEN", ":8443"),
		Handler:           apiMux,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       5 * time.Second,
		WriteTimeout:      5 * time.Second,
		IdleTimeout:       30 * time.Second,
	}

	healthMux := http.NewServeMux()
	healthMux.HandleFunc("GET /healthz", func(writer http.ResponseWriter, _ *http.Request) {
		writer.Header().Set("Content-Type", "text/plain; charset=utf-8")
		writer.WriteHeader(http.StatusOK)
		_, _ = writer.Write([]byte("ok\n"))
	})
	healthServer := &http.Server{
		Addr:              envOrDefault("RIDENOW_HEALTH_LISTEN", ":8080"),
		Handler:           healthMux,
		ReadHeaderTimeout: 2 * time.Second,
		ReadTimeout:       2 * time.Second,
		WriteTimeout:      2 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	errorsChannel := make(chan error, 2)
	go func() {
		logger.Info("access API listening", "address", apiServer.Addr)
		errorsChannel <- apiServer.ListenAndServeTLS(tlsCertificate, tlsKey)
	}()
	go func() {
		logger.Info("health endpoint listening", "address", healthServer.Addr)
		errorsChannel <- healthServer.ListenAndServe()
	}()

	select {
	case <-ctx.Done():
	case err := <-errorsChannel:
		if !errors.Is(err, http.ErrServerClosed) {
			logger.Error("server stopped unexpectedly", "error", err)
		}
	}

	shutdownContext, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = apiServer.Shutdown(shutdownContext)
	_ = healthServer.Shutdown(shutdownContext)
}

func sessionHandler(logger *slog.Logger, accessFile string) http.HandlerFunc {
	return func(writer http.ResponseWriter, request *http.Request) {
		request.Body = http.MaxBytesReader(writer, request.Body, 32*1024)
		decoder := json.NewDecoder(request.Body)
		decoder.DisallowUnknownFields()
		var body sessionRequest
		if err := decoder.Decode(&body); err != nil {
			writeJSON(writer, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
			return
		}
		if strings.TrimSpace(body.DeviceID) == "" || strings.TrimSpace(body.PublicKeyA) == "" || strings.TrimSpace(body.PublicKeyB) == "" {
			writeJSON(writer, http.StatusBadRequest, map[string]string{"error": "missing_device_or_peer_keys"})
			return
		}

		document, err := access.Load(accessFile)
		if err != nil {
			logger.Error("access file rejected; failing closed", "error", err)
			writeJSON(writer, http.StatusServiceUnavailable, map[string]string{"error": "authorization_unavailable"})
			return
		}
		id, _, authorized := access.Authorize(document, body.Token)
		if !authorized {
			logger.Warn("access denied", "deviceId", body.DeviceID)
			writeJSON(writer, http.StatusUnauthorized, map[string]string{"error": "access_denied"})
			return
		}

		logger.Info("access granted", "keyId", id, "deviceId", body.DeviceID)
		writeJSON(writer, http.StatusOK, sessionResponse{
			Status:              "authorized",
			LeaseSeconds:        10,
			DirectEndpoint:      os.Getenv("RIDENOW_DIRECT_ENDPOINT"),
			AcceleratedEndpoint: os.Getenv("RIDENOW_ACCELERATED_ENDPOINT"),
		})
	}
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
