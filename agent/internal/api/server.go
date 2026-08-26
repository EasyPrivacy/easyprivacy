package api

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"strings"

	"github.com/easyprivacy/easyprivacy/agent/internal/system"
)

type StatusCollector interface {
	Collect(context.Context) (system.Status, error)
}

type handler struct {
	authenticator Authenticator
	collector     StatusCollector
	mux           *http.ServeMux
}

func NewHandler(authenticator Authenticator, collector StatusCollector) http.Handler {
	h := &handler{
		authenticator: authenticator,
		collector:     collector,
		mux:           http.NewServeMux(),
	}
	h.mux.HandleFunc("GET /healthz", h.health)
	h.mux.HandleFunc("GET /v1/status", h.authenticated(h.status))
	return h.securityHeaders(h.mux)
}

func (h *handler) health(response http.ResponseWriter, _ *http.Request) {
	writeJSON(response, http.StatusOK, map[string]string{"status": "ok"})
}

func (h *handler) status(response http.ResponseWriter, request *http.Request) {
	status, err := h.collector.Collect(request.Context())
	if err != nil {
		slog.Error("collect system status", "error", err)
		writeJSON(response, http.StatusInternalServerError, map[string]string{
			"error": "system status is temporarily unavailable",
		})
		return
	}
	writeJSON(response, http.StatusOK, status)
}

func (h *handler) authenticated(next http.HandlerFunc) http.HandlerFunc {
	return func(response http.ResponseWriter, request *http.Request) {
		const prefix = "Bearer "
		header := request.Header.Get("Authorization")
		if !strings.HasPrefix(header, prefix) {
			unauthorized(response)
			return
		}
		authenticated, err := h.authenticator.Authenticate(
			request.Context(),
			strings.TrimSpace(header[len(prefix):]),
		)
		if err != nil {
			slog.Error("authenticate management request", "error", err)
			writeJSON(response, http.StatusServiceUnavailable, map[string]string{
				"error": "device authentication is temporarily unavailable",
			})
			return
		}
		if !authenticated {
			unauthorized(response)
			return
		}
		next(response, request)
	}
}

func (h *handler) securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		response.Header().Set("Cache-Control", "no-store")
		response.Header().Set("X-Content-Type-Options", "nosniff")
		response.Header().Set("Referrer-Policy", "no-referrer")
		next.ServeHTTP(response, request)
	})
}

func unauthorized(response http.ResponseWriter) {
	response.Header().Set("WWW-Authenticate", "Bearer")
	writeJSON(response, http.StatusUnauthorized, map[string]string{
		"error": "valid device credentials are required",
	})
}

func writeJSON(response http.ResponseWriter, statusCode int, value any) {
	response.Header().Set("Content-Type", "application/json")
	response.WriteHeader(statusCode)
	if err := json.NewEncoder(response).Encode(value); err != nil {
		slog.Error("encode API response", "error", err)
	}
}
