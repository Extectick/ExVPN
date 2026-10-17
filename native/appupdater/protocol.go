// SPDX-License-Identifier: Apache-2.0
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"strings"
)

type request struct {
	Protocol  int    `json:"protocol"`
	Version   string `json:"version,omitempty"`
	ParentPID int    `json:"parentPid,omitempty"`
}

type response struct {
	Type      string `json:"type"`
	Status    string `json:"status,omitempty"`
	Version   string `json:"version,omitempty"`
	Size      int64  `json:"sizeBytes,omitempty"`
	ErrorCode string `json:"errorCode,omitempty"`
	Received  int64  `json:"received,omitempty"`
	Total     int64  `json:"total,omitempty"`
}

func readRequest(in io.Reader, command string) (request, error) {
	r := bufio.NewReader(io.LimitReader(in, maxPayload+1))
	b, err := r.ReadBytes('\n')
	if err != nil && err != io.EOF {
		return request{}, safeError("invalid_request")
	}
	if len(b) == 0 || len(b) > maxPayload {
		return request{}, safeError("invalid_request")
	}
	if _, err := r.ReadByte(); err != io.EOF {
		return request{}, safeError("invalid_request")
	}
	if bytes.Contains(bytes.TrimSpace(b), []byte{'\n'}) {
		return request{}, safeError("invalid_request")
	}
	var req request
	if err := strictJSON(bytes.TrimSpace(b), maxPayload, &req); err != nil || req.Protocol != 1 {
		return request{}, safeError("invalid_request")
	}
	switch command {
	case "check":
		if req.Version != "" || req.ParentPID != 0 {
			return request{}, safeError("invalid_request")
		}
	case "download":
		if !validIdentity(req.Version) || req.ParentPID != 0 {
			return request{}, safeError("invalid_request")
		}
	case "handoff":
		if !validIdentity(req.Version) || req.ParentPID < 1 {
			return request{}, safeError("invalid_request")
		}
	case "restart-ui":
		if req.Version != "" || req.ParentPID < 1 {
			return request{}, safeError("invalid_request")
		}
	default:
		return request{}, safeError("invalid_request")
	}
	return req, nil
}

func validIdentity(value string) bool {
	parts := strings.Split(value, "+")
	if len(parts) != 2 || !validVersion(parts[0]) || len(parts[1]) == 0 || len(parts[1]) > 10 || parts[1][0] == '0' {
		return false
	}
	var n int64
	for _, c := range parts[1] {
		if c < '0' || c > '9' {
			return false
		}
		n = n*10 + int64(c-'0')
	}
	return n >= 1 && n <= maxBuild
}

func emit(out io.Writer, r response) error { return json.NewEncoder(out).Encode(r) }
func result(status string, m manifest) response {
	r := response{Type: "result", Status: status}
	if m.Version != "" {
		r.Version = m.identity()
		r.Size = m.Asset.Size
	}
	return r
}

func errorResponse(err error) response {
	code := "operation_failed"
	if e, ok := err.(safeError); ok {
		switch string(e) {
		case "invalid_request", "not_configured", "unsupported_platform", "network_failed", "manifest_invalid", "signature_invalid", "update_incompatible", "update_expired", "download_failed", "integrity_failed", "cache_unavailable", "update_not_ready", "installed_app_required", "owner_invalid", "permission_denied", "handoff_failed", "operation_busy", "operation_failed", "previous_install_failed":
			code = string(e)
		}
	}
	return response{Type: "result", Status: "error", ErrorCode: code}
}
