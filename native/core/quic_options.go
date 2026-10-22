// SPDX-License-Identifier: Apache-2.0
package exvpn

// Remote QUIC liveness/flow-control settings only. No paths, logging switches,
// TLS overrides, masks, routes, DNS, listeners or arbitrary core objects.
type QuicOptions struct {
	Congestion                  string `json:"congestion,omitempty"`
	InitStreamReceiveWindow     int    `json:"initStreamReceiveWindow,omitempty"`
	MaxStreamReceiveWindow      int    `json:"maxStreamReceiveWindow,omitempty"`
	InitConnectionReceiveWindow int    `json:"initConnectionReceiveWindow,omitempty"`
	MaxConnectionReceiveWindow  int    `json:"maxConnectionReceiveWindow,omitempty"`
	MaxIdleTimeout              int    `json:"maxIdleTimeout,omitempty"`
	KeepAlivePeriod             int    `json:"keepAlivePeriod,omitempty"`
}

func (q QuicOptions) valid() bool {
	if !oneOf(q.Congestion, "", "bbr", "reno") {
		return false
	}
	for _, window := range []struct{ value, max int }{
		{q.InitStreamReceiveWindow, 16 << 20}, {q.MaxStreamReceiveWindow, 16 << 20},
		{q.InitConnectionReceiveWindow, 64 << 20}, {q.MaxConnectionReceiveWindow, 64 << 20},
	} {
		if window.value != 0 && (window.value < 16384 || window.value > window.max) {
			return false
		}
	}
	if (q.MaxIdleTimeout != 0 && (q.MaxIdleTimeout < 4 || q.MaxIdleTimeout > 120)) ||
		(q.KeepAlivePeriod != 0 && (q.KeepAlivePeriod < 2 || q.KeepAlivePeriod > 60)) {
		return false
	}
	value := func(n, fallback int) int {
		if n == 0 {
			return fallback
		}
		return n
	}
	streamMax := value(q.MaxStreamReceiveWindow, 8388608)
	connectionMax := value(q.MaxConnectionReceiveWindow, 20971520)
	return value(q.InitStreamReceiveWindow, 8388608) <= streamMax &&
		value(q.InitConnectionReceiveWindow, 20971520) <= connectionMax &&
		streamMax <= connectionMax && q.KeepAlivePeriod < value(q.MaxIdleTimeout, 30)
}
