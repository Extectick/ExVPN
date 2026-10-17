// SPDX-License-Identifier: Apache-2.0
package service

import (
	"bytes"
	"encoding/json"

	exvpn "github.com/Extectick/ExVPN/native/core"
)

// PolicyStore contains only locally confirmed exclusions, never a provider
// profile or an automatic permission to release a recovered guard.
type PolicyStore interface {
	Load() ([]string, error)
	Save([]string) error
}

type ApplicationRoutingStore interface {
	LoadRouting() (ApplicationRoutingPolicy, error)
	SaveRouting(ApplicationRoutingPolicy) error
}

type routingPolicyDocument struct {
	Version      int      `json:"version"`
	Owner        string   `json:"owner"`
	Mode         string   `json:"mode"`
	Applications []string `json:"applications"`
}

func encodeRoutingPolicy(owner string, policy ApplicationRoutingPolicy) ([]byte, error) {
	if policy.validate() != nil {
		return nil, Code("application_routing_rejected")
	}
	policy = policy.clone()
	b, err := json.Marshal(routingPolicyDocument{Version: 2, Owner: owner, Mode: policy.Mode, Applications: policy.Applications})
	if err != nil || len(b) > maxPolicyBytes {
		return nil, Code("native_storage_unavailable")
	}
	return b, nil
}

func decodeRoutingPolicy(owner string, b []byte) (ApplicationRoutingPolicy, error) {
	if len(b) == 0 || len(b) > maxPolicyBytes || checkJSON(b) != nil {
		return ApplicationRoutingPolicy{}, Code("exclusions_unavailable")
	}
	var version struct {
		Version int `json:"version"`
	}
	if json.Unmarshal(b, &version) != nil {
		return ApplicationRoutingPolicy{}, Code("exclusions_unavailable")
	}
	if version.Version == 1 {
		paths, err := decodePolicy(owner, b)
		return legacyApplicationRouting(paths).clone(), err
	}
	var doc routingPolicyDocument
	d := json.NewDecoder(bytes.NewReader(b))
	d.DisallowUnknownFields()
	p := ApplicationRoutingPolicy{}
	if d.Decode(&doc) == nil {
		p = ApplicationRoutingPolicy{Mode: doc.Mode, Applications: doc.Applications}
	}
	if doc.Version != 2 || doc.Owner != owner || p.validate() != nil {
		return ApplicationRoutingPolicy{}, Code("exclusions_unavailable")
	}
	return p.clone(), nil
}

const policyMissing = Code("policy_missing")
const maxPolicyBytes = 256 << 10

type policyDocument struct {
	Version int      `json:"version"`
	Owner   string   `json:"owner"`
	Paths   []string `json:"paths"`
}

func validatePolicyPaths(paths []string) error {
	if len(paths) > 128 {
		return Code("exclusions_rejected")
	}
	if _, err := (exvpn.RoutingPolicy{WindowsExecutablePaths: paths}).Rules("vpn"); err != nil {
		return Code("exclusions_rejected")
	}
	return nil
}

func encodePolicy(owner string, paths []string) ([]byte, error) {
	if validatePolicyPaths(paths) != nil {
		return nil, Code("exclusions_rejected")
	}
	b, err := json.Marshal(policyDocument{Version: 1, Owner: owner, Paths: append([]string{}, paths...)})
	if err != nil || len(b) > maxPolicyBytes {
		return nil, Code("native_storage_unavailable")
	}
	return b, nil
}

func decodePolicy(owner string, b []byte) ([]string, error) {
	if len(b) == 0 || len(b) > maxPolicyBytes || checkJSON(b) != nil {
		return nil, Code("exclusions_unavailable")
	}
	var value policyDocument
	d := json.NewDecoder(bytes.NewReader(b))
	d.DisallowUnknownFields()
	if d.Decode(&value) != nil || value.Version != 1 || value.Owner != owner || value.Paths == nil || validatePolicyPaths(value.Paths) != nil {
		return nil, Code("exclusions_unavailable")
	}
	return value.Paths, nil
}

type unavailablePolicyStore struct{}

func (unavailablePolicyStore) Load() ([]string, error) { return nil, Code("exclusions_unavailable") }
func (unavailablePolicyStore) Save([]string) error     { return Code("native_storage_unavailable") }
