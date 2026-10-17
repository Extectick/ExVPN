// SPDX-License-Identifier: Apache-2.0
package main

func validRoutingMode(mode string) bool {
	return mode == "disabled" || mode == "exclude" || mode == "include"
}
