// SPDX-License-Identifier: Apache-2.0
package service

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"io"
	"regexp"
	"strings"

	exvpn "github.com/Extectick/ExVPN/native/core"
)

const ProtocolVersion = 1
const MaxFrameBytes = exvpn.MaxProfileBytes + 8192

type Code string

func (c Code) Error() string { return string(c) }

// No raw configs, arbitrary commands, paths to a core executable or URLs cross IPC.
type Request struct {
	Version            int                       `json:"version"`
	ID                 string                    `json:"id"`
	Command            string                    `json:"command"`
	Profile            json.RawMessage           `json:"profile,omitempty"`
	Exclusions         []string                  `json:"exclusions,omitempty"`
	Mode               string                    `json:"mode,omitempty"`
	ApplicationRouting *ApplicationRoutingPolicy `json:"applicationRouting,omitempty"`
	AutomaticProfiles  []json.RawMessage         `json:"automaticProfiles,omitempty"`
	Enabled            *bool                     `json:"enabled,omitempty"`
	SiteRouting        *exvpn.SiteRoutingState   `json:"siteRouting,omitempty"`
}

type Capabilities struct {
	SystemTunnel          bool `json:"systemTunnel"`
	SystemProxy           bool `json:"systemProxy"`
	PersistentGuard       bool `json:"persistentGuard"`
	ApplicationExclusions bool `json:"applicationExclusions"`
	Verified              bool `json:"verified"`
}
type Status struct {
	State                 string       `json:"state"`
	Code                  string       `json:"code"`
	GuardActive           bool         `json:"guardActive"`
	PersistentGuardActive bool         `json:"persistentGuardActive"`
	ConnectedAt           int64        `json:"connectedAt,omitempty"`
	CoreVersion           string       `json:"coreVersion"`
	ActiveProfileID       string       `json:"activeProfileId,omitempty"`
	Capabilities          Capabilities `json:"capabilities"`
	Mode                  string       `json:"mode"`
	ProxyPort             int          `json:"proxyPort"`
	AutomaticSelection    bool         `json:"automaticSelection"`
}
type Response struct {
	Version              int                       `json:"version"`
	ID                   string                    `json:"id,omitempty"`
	OK                   bool                      `json:"ok"`
	Code                 string                    `json:"code"`
	Status               Status                    `json:"status"`
	Probe                *ProbeResult              `json:"probe,omitempty"`
	Traffic              *Traffic                  `json:"traffic,omitempty"`
	Exclusions           []string                  `json:"exclusions,omitempty"`
	ApplicationRouting   *ApplicationRoutingPolicy `json:"applicationRouting,omitempty"`
	ConnectionProtection *ConnectionProtection     `json:"connectionProtection,omitempty"`
	SiteRouting          *exvpn.SiteRoutingState   `json:"siteRouting,omitempty"`
}
type Traffic struct {
	UploadBytes   int64 `json:"uploadBytes"`
	DownloadBytes int64 `json:"downloadBytes"`
}
type ProbeResult struct {
	Reachable bool   `json:"reachable"`
	LatencyMS int64  `json:"latencyMs,omitempty"`
	ErrorCode string `json:"errorCode,omitempty"`
}

var requestID = regexp.MustCompile(`^[a-zA-Z0-9_-]{1,64}$`)

func ReadFrame(r io.Reader) ([]byte, error) {
	var header [4]byte
	if _, err := io.ReadFull(r, header[:]); err != nil {
		return nil, Code("ipc_read_failed")
	}
	n := binary.LittleEndian.Uint32(header[:])
	if n == 0 || n > MaxFrameBytes {
		return nil, Code("ipc_frame_size")
	}
	b := make([]byte, n)
	if _, err := io.ReadFull(r, b); err != nil {
		return nil, Code("ipc_read_failed")
	}
	return b, nil
}
func WriteFrame(w io.Writer, v any) error {
	b, err := json.Marshal(v)
	if err != nil || len(b) > MaxFrameBytes {
		return Code("ipc_write_failed")
	}
	var header [4]byte
	binary.LittleEndian.PutUint32(header[:], uint32(len(b)))
	for _, part := range [][]byte{header[:], b} {
		for len(part) > 0 {
			n, e := w.Write(part)
			if e != nil || n == 0 {
				return Code("ipc_write_failed")
			}
			part = part[n:]
		}
	}
	return nil
}

func DecodeRequest(b []byte) (Request, error) {
	if len(b) == 0 || len(b) > MaxFrameBytes || checkJSON(b) != nil {
		return Request{}, Code("ipc_invalid_json")
	}
	d := json.NewDecoder(bytes.NewReader(b))
	d.DisallowUnknownFields()
	type requestFields Request
	var wire struct {
		requestFields
		SiteRouting json.RawMessage `json:"siteRouting"`
	}
	if d.Decode(&wire) != nil {
		return Request{}, Code("ipc_invalid_request")
	}
	r := Request(wire.requestFields)
	if r.Version != ProtocolVersion || !requestID.MatchString(r.ID) {
		return Request{}, Code("ipc_invalid_request")
	}
	var fields map[string]json.RawMessage
	_ = json.Unmarshal(b, &fields)
	for key := range fields {
		if key != "siteRouting" && strings.EqualFold(key, "siteRouting") {
			return Request{}, Code("site_routing_rejected")
		}
	}
	_, hasMode := fields["mode"]
	if _, present := fields["enabled"]; present && r.Command != "setConnectionProtection" {
		return Request{}, Code("ipc_unexpected_payload")
	}
	if hasMode && r.Mode != ModeVPN && r.Mode != ModeProxy {
		return Request{}, Code("connection_mode_rejected")
	}
	if hasMode && r.Command != "connect" && r.Command != "reconnect" {
		return Request{}, Code("ipc_unexpected_payload")
	}
	if r.ApplicationRouting != nil && r.Command != "setApplicationRouting" {
		return Request{}, Code("ipc_unexpected_payload")
	}
	if len(wire.SiteRouting) != 0 && r.Command != "set_site_routing" {
		return Request{}, Code("ipc_unexpected_payload")
	}
	if _, present := fields["automaticProfiles"]; present {
		if (r.Command != "connect" && r.Command != "reconnect") || len(r.AutomaticProfiles) == 0 || len(r.AutomaticProfiles) > 32 {
			return Request{}, Code("automatic_group_rejected")
		}
		for _, raw := range r.AutomaticProfiles {
			if _, err := exvpn.DecodeProfile(bytes.NewReader(raw)); err != nil {
				return Request{}, Code("automatic_group_rejected")
			}
		}
	}
	switch r.Command {
	case "status", "stats", "disconnect", "getExclusions", "getApplicationRouting", "clearAutomaticSelection", "getConnectionProtection", "get_site_routing":
		if len(r.Profile) != 0 || r.Exclusions != nil {
			return Request{}, Code("ipc_unexpected_payload")
		}
	case "setConnectionProtection":
		if r.Enabled == nil || len(r.Profile) != 0 || r.Exclusions != nil {
			return Request{}, Code("ipc_invalid_payload")
		}
	case "setExclusions":
		if len(r.Profile) != 0 || r.Exclusions == nil || len(r.Exclusions) > 128 {
			return Request{}, Code("ipc_invalid_payload")
		}
		if _, e := (exvpn.RoutingPolicy{WindowsExecutablePaths: r.Exclusions}).Rules("vpn"); e != nil {
			return Request{}, Code("exclusions_rejected")
		}
	case "setApplicationRouting":
		if len(r.Profile) != 0 || r.Exclusions != nil || r.ApplicationRouting == nil || r.ApplicationRouting.validate() != nil {
			return Request{}, Code("application_routing_rejected")
		}
	case "set_site_routing":
		if len(r.Profile) != 0 || r.Exclusions != nil || r.ApplicationRouting != nil {
			return Request{}, Code("site_routing_rejected")
		}
		state, err := exvpn.DecodeSiteRoutingState(fields["siteRouting"])
		if err != nil {
			return Request{}, Code("site_routing_rejected")
		}
		r.SiteRouting = &state
	case "connect", "reconnect", "validate", "probe":
		if len(r.Profile) == 0 || len(r.Exclusions) > 128 {
			return Request{}, Code("ipc_invalid_payload")
		}
		if _, e := exvpn.DecodeProfile(bytes.NewReader(r.Profile)); e != nil {
			return Request{}, Code("profile_rejected")
		}
		if _, e := (exvpn.RoutingPolicy{WindowsExecutablePaths: r.Exclusions}).Rules("vpn"); e != nil {
			return Request{}, Code("exclusions_rejected")
		}
		if r.Mode == ModeProxy && r.Exclusions != nil {
			return Request{}, Code("proxy_exclusions_unsupported")
		}
	default:
		return Request{}, Code("ipc_unknown_command")
	}
	return r, nil
}

// Duplicate keys and null are rejected before decoding typed structs. The depth
// bound also prevents pathological nested input consuming the service stack.
func checkJSON(b []byte) error {
	d := json.NewDecoder(bytes.NewReader(b))
	d.UseNumber()
	var value func(int) error
	value = func(depth int) error {
		if depth > 16 {
			return Code("depth")
		}
		t, err := d.Token()
		if err != nil || t == nil {
			return Code("json")
		}
		if delimiter, ok := t.(json.Delim); ok {
			switch delimiter {
			case '{':
				seen := map[string]bool{}
				for d.More() {
					key, e := d.Token()
					if e != nil {
						return e
					}
					k, ok := key.(string)
					if !ok || seen[k] {
						return Code("duplicate")
					}
					seen[k] = true
					if e = value(depth + 1); e != nil {
						return e
					}
				}
			case '[':
				for d.More() {
					if e := value(depth + 1); e != nil {
						return e
					}
				}
			default:
				return Code("json")
			}
			_, err = d.Token()
			return err
		}
		return nil
	}
	if err := value(0); err != nil {
		return err
	}
	if _, err := d.Token(); err != io.EOF {
		return Code("trailing")
	}
	return nil
}
