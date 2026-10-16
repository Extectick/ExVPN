// SPDX-License-Identifier: Apache-2.0
package exvpn

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
)

func TestVLESSEncryptionValidatesBoundedAuthenticatedParameters(t *testing.T) {
	xKey, _ := syntheticEncryptionKeyPair(t, "x25519")
	mKey, _ := syntheticEncryptionKeyPair(t, "mlkem768")
	for _, mode := range []string{"native", "xorpub", "random"} {
		for _, rtt := range []string{"0rtt", "1rtt"} {
			for name, keys := range map[string]string{
				"x25519":         xKey,
				"mlkem768":       mKey,
				"four-key-chain": strings.Join([]string{xKey, mKey, xKey, mKey}, "."),
			} {
				t.Run(mode+"/"+rtt+"/"+name, func(t *testing.T) {
					p := fixture("vless")
					p.TLS = TLS{}
					p.Encryption = "mlkem768x25519plus." + mode + "." + rtt + "." + keys
					if _, err := Compile(p); err != nil {
						t.Fatalf("valid authenticated encryption rejected: %v", err)
					}
				})
			}
		}
	}

	prefix := "mlkem768x25519plus.native.0rtt."
	for name, padding := range map[string]string{
		"minimum":            "100-35-35",
		"maximum-length":     "100-65553-65553",
		"bounded-gap":        "100-35-35.100-1000-1000.0-0-65518",
		"fifteen-components": "100-35-35" + strings.Repeat(".0-0-0", 14),
	} {
		t.Run(name, func(t *testing.T) {
			p := fixture("vless")
			p.Encryption = prefix + padding + "." + xKey
			if _, err := Compile(p); err != nil {
				t.Fatalf("valid bounded padding rejected: %v", err)
			}
		})
	}

	// The final base64 symbol has only four significant bits for a 32-byte key.
	// Alter only its unused bits: permissive decoders accept the same bytes,
	// whereas the native boundary must reject this noncanonical spelling.
	alphabet := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
	last := strings.IndexByte(alphabet, xKey[len(xKey)-1])
	noncanonicalKey := xKey[:len(xKey)-1] + string(alphabet[last+1])
	invalid := map[string]string{
		"empty":                      "",
		"none-is-not-extension":      "none",
		"unknown-algorithm":          "unknown.native.0rtt." + xKey,
		"unknown-mode":               "mlkem768x25519plus.unknown.0rtt." + xKey,
		"unknown-rtt":                "mlkem768x25519plus.native.2rtt." + xKey,
		"no-key":                     prefix + "100-35-35",
		"blank-key":                  prefix,
		"five-keys":                  prefix + strings.TrimSuffix(strings.Repeat(xKey+".", 5), "."),
		"31-byte-key":                prefix + base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{1}, 31)),
		"33-byte-key":                prefix + base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{1}, 33)),
		"zero-x25519":                prefix + base64.RawURLEncoding.EncodeToString(make([]byte, 32)),
		"zero-mlkem":                 prefix + base64.RawURLEncoding.EncodeToString(make([]byte, 1184)),
		"invalid-mlkem-coefficients": prefix + base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{255}, 1184)),
		"padded-base64":              prefix + xKey + "=",
		"noncanonical-base64":        prefix + noncanonicalKey,
		"invalid-base64":             prefix + strings.Repeat("!", 43),
		"whitespace":                 prefix + xKey + " ",
		"linebreak":                  prefix + xKey + "\n",
		"padding-after-key":          prefix + xKey + ".100-35-35",
		"padding-not-numeric":        prefix + "100-a-b." + xKey,
		"padding-negative":           prefix + "100--1-35." + xKey,
		"padding-leading-zero":       prefix + "100-035-35." + xKey,
		"padding-probability":        prefix + "101-35-35." + xKey,
		"first-padding-optional":     prefix + "99-35-35." + xKey,
		"first-padding-small":        prefix + "100-34-35." + xKey,
		"padding-reversed":           prefix + "100-36-35." + xKey,
		"padding-too-large":          prefix + "100-35-65554." + xKey,
		"gap-too-large":              prefix + "100-35-35.100-0-1001." + xKey,
		"padding-total-too-large":    prefix + "100-35-35.0-0-0.100-65519-65519." + xKey,
		"sixteen-components":         prefix + "100-35-35" + strings.Repeat(".0-0-0", 15) + "." + xKey,
		"integer-overflow":           prefix + "100-999999999999999999999-999999999999999999999." + xKey,
		"over-limit":                 prefix + strings.Repeat("A", 8193),
	}
	for name, value := range invalid {
		t.Run(name, func(t *testing.T) {
			if validVlessEncryption(value) {
				t.Fatal("malformed or unbounded encryption was accepted")
			}
		})
	}
}

func TestEncryptionAndSudokuNativeJSONRejectsWrongTypesAndControlFields(t *testing.T) {
	key, _ := syntheticEncryptionKeyPair(t, "x25519")
	p := fixture("vless")
	p.TLS = TLS{}
	p.Encryption = "mlkem768x25519plus.native.0rtt." + key
	p.Transport.TCPSudoku = &Sudoku{Password: "synthetic-private-mask", ASCII: "prefer_entropy", CustomTables: []string{"xxppvvvv"}, PaddingMin: 1, PaddingMax: 2}
	b, err := json.Marshal(p)
	if err != nil {
		t.Fatal("could not encode synthetic profile")
	}
	base := string(b)
	maskJSON, err := json.Marshal(p.Transport.TCPSudoku)
	if err != nil {
		t.Fatal("could not encode synthetic Sudoku configuration")
	}
	if _, err := DecodeProfile(strings.NewReader(base)); err != nil {
		t.Fatalf("valid typed extensions rejected: %v", err)
	}
	cases := map[string]string{}
	for _, value := range []string{`null`, `true`, `123`, `"text"`, `[]`, `{}`} {
		cases["encryption-type-"+value] = strings.Replace(base, `"encryption":"`+p.Encryption+`"`, `"encryption":`+value, 1)
		cases["sudoku-type-"+value] = strings.Replace(base, `"tcpSudoku":`+string(maskJSON), `"tcpSudoku":`+value, 1)
		if value != `"text"` {
			cases["password-type-"+value] = strings.Replace(base, `"password":"synthetic-private-mask"`, `"password":`+value, 1)
		}
	}
	for name, replacement := range map[string]string{
		"unknown-mask":           `"type":"xmc",`,
		"listener":               `"listen":"127.0.0.1",`,
		"certificate":            `"certificateFile":"private.pem",`,
		"duplicate-password":     `"password":"other",`,
		"case-insensitive-alias": `"Password":"other",`,
		"legacy-padding-field":   `"padding_min":1,`,
		"remote-address":         `"address":"example.com",`,
	} {
		cases[name] = strings.Replace(base, `"tcpSudoku":{`, `"tcpSudoku":{`+replacement, 1)
	}
	cases["sudoku-array"] = strings.Replace(base, `"tcpSudoku":`+string(maskJSON), `"tcpSudoku":[`+string(maskJSON)+`]`, 1)
	cases["string-padding"] = strings.Replace(base, `"paddingMin":1`, `"paddingMin":"1"`, 1)
	cases["float-padding"] = strings.Replace(base, `"paddingMin":1`, `"paddingMin":1.5`, 1)
	cases["overflow-padding"] = strings.Replace(base, `"paddingMin":1`, `"paddingMin":18446744073709551616`, 1)
	cases["nonstring-table"] = strings.Replace(base, `"customTables":["xxppvvvv"]`, `"customTables":[123]`, 1)
	cases["string-tables"] = strings.Replace(base, `"customTables":["xxppvvvv"]`, `"customTables":"xxppvvvv"`, 1)
	cases["bool-ascii"] = strings.Replace(base, `"ascii":"prefer_entropy"`, `"ascii":true`, 1)
	cases["duplicate-encryption"] = strings.Replace(base, `"encryption":`, `"encryption":"none","encryption":`, 1)
	for name, raw := range cases {
		t.Run(name, func(t *testing.T) {
			if raw == base || !json.Valid([]byte(raw)) {
				t.Fatal("negative schema fixture was not a valid modified JSON document")
			}
			_, err := DecodeProfile(strings.NewReader(raw))
			if err == nil {
				t.Fatal("malformed extension or provider control accepted")
			}
			if _, ok := err.(CodeError); !ok || strings.Contains(err.Error(), "synthetic-private-mask") || strings.Contains(err.Error(), key) {
				t.Fatal("native decode exposed provider values instead of a safe code")
			}
		})
	}
}

func TestSudokuBoundsAndAuthenticatedTransport(t *testing.T) {
	key, _ := syntheticEncryptionKeyPair(t, "x25519")
	base := fixture("vless")
	base.TLS = TLS{}
	base.Encryption = "mlkem768x25519plus.native.0rtt." + key
	valid := []Sudoku{
		{Password: "synthetic-mask"},
		{Password: "synthetic-mask", ASCII: "prefer_ascii", PaddingMin: 0, PaddingMax: 100},
		{Password: "synthetic-mask", ASCII: "prefer_entropy", CustomTables: []string{"xxppvvvv", "xpxpvvvv", "vvvvppxx", "ppxxvvvv"}, PaddingMin: 100, PaddingMax: 100},
		{Password: strings.Repeat("s", 4096)},
	}
	for i := range valid {
		p := base
		p.Transport.TCPSudoku = &valid[i]
		if _, err := Compile(p); err != nil {
			t.Fatalf("valid Sudoku configuration %d rejected: %v", i, err)
		}
	}
	invalid := map[string]Sudoku{
		"empty-password":       {},
		"password-over-limit":  {Password: strings.Repeat("s", 4097)},
		"null-character":       {Password: "synthetic\x00mask"},
		"newline":              {Password: "synthetic\nmask"},
		"tab":                  {Password: "synthetic\tmask"},
		"del":                  {Password: "synthetic\x7fmask"},
		"unknown-ascii":        {Password: "synthetic-mask", ASCII: "guess"},
		"ignored-custom-table": {Password: "synthetic-mask", ASCII: "prefer_ascii", CustomTables: []string{"xxppvvvv"}},
		"short-table":          {Password: "synthetic-mask", CustomTables: []string{"xxppvvv"}},
		"wrong-counts":         {Password: "synthetic-mask", CustomTables: []string{"xxxpvvvv"}},
		"unknown-table-symbol": {Password: "synthetic-mask", CustomTables: []string{"xxppvvv!"}},
		"duplicate-tables":     {Password: "synthetic-mask", CustomTables: []string{"xxppvvvv", "xxppvvvv"}},
		"too-many-tables":      {Password: "synthetic-mask", CustomTables: []string{"xxppvvvv", "xpxpvvvv", "vvvvppxx", "ppxxvvvv", "xppxvvvv"}},
		"negative-padding":     {Password: "synthetic-mask", PaddingMin: -1},
		"reversed-padding":     {Password: "synthetic-mask", PaddingMin: 2, PaddingMax: 1},
		"too-large-padding":    {Password: "synthetic-mask", PaddingMax: 101},
	}
	for name, s := range invalid {
		t.Run(name, func(t *testing.T) {
			p := base
			p.Transport.TCPSudoku = &s
			if _, err := Compile(p); err != CodeError("profile_invalid_sudoku") {
				t.Fatal("invalid Sudoku was accepted or produced an unsafe error")
			}
		})
	}
	for name, mutate := range map[string]func(*Profile){
		"unauthenticated":              func(p *Profile) { p.Encryption = "" },
		"websocket":                    func(p *Profile) { p.Transport.Type = "ws" },
		"vmess":                        func(p *Profile) { p.Protocol = "vmess" },
		"vision-without-peer-security": func(p *Profile) { p.Encryption = ""; p.Flow = "xtls-rprx-vision" },
	} {
		t.Run(name, func(t *testing.T) {
			p := base
			p.Transport.TCPSudoku = &Sudoku{Password: "synthetic-mask"}
			mutate(&p)
			if _, err := Compile(p); err == nil {
				t.Fatal("Sudoku bypassed transport authentication constraints")
			}
		})
	}
}
