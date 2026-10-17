// SPDX-License-Identifier: Apache-2.0
//go:build !windows

package main

import "os"

func ordinaryUser() error                            { return safeError("unsupported_platform") }
func openStore(bool) (*store, error)                 { return nil, safeError("unsupported_platform") }
func secureNewFile(string, string) (*os.File, error) { return nil, safeError("unsupported_platform") }
func secureReadFile(string, string, bool) (*os.File, error) {
	return nil, safeError("unsupported_platform")
}
func beginHandoff(request, trustedConfig, *store) (response, error) {
	return response{}, safeError("unsupported_platform")
}
func workerMain() { _ = emit(os.Stdout, errorResponse(safeError("unsupported_platform"))) }
