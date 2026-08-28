package main

import (
	"log/slog"
	"net/http"
	"os"
	"time"
)

// This process is the lifecycle shell for the relay. The packet encapsulation,
// TUN wiring and WireGuard peer control are implemented in the next MVP slice.
func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(writer http.ResponseWriter, _ *http.Request) {
		writer.WriteHeader(http.StatusOK)
		_, _ = writer.Write([]byte("ok\n"))
	})
	server := &http.Server{
		Addr:              ":8081",
		Handler:           mux,
		ReadHeaderTimeout: 2 * time.Second,
	}
	logger.Info("relay lifecycle process started", "status", "data-plane-not-enabled")
	if err := server.ListenAndServe(); err != nil {
		logger.Error("relay stopped", "error", err)
		os.Exit(1)
	}
}
