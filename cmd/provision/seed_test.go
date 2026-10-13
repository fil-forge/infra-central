package main

import (
	"strings"
	"testing"
)

func TestJoinPartnerKeysRendersTheCSVHiltSplits(t *testing.T) {
	got, err := joinPartnerKeys([]string{"aa11", "bb22"})
	if got != "aa11,bb22" || err != nil {
		t.Errorf("joinPartnerKeys() = %q, %v; want %q, nil", got, err, "aa11,bb22")
	}
}

// Hilt compares keys byte for byte, so each of these would leave a consumer
// locked out without any error. The message names the parameter and never the
// key.
func TestJoinPartnerKeysRefusesAKeyHiltCouldNeverMatch(t *testing.T) {
	cases := []struct {
		desc string
		keys []string
		want string
	}{
		{desc: "an empty key", keys: []string{"aa11", ""}, want: "partner-key-ci is empty"},
		{desc: "a key holding a comma", keys: []string{"aa,11", "bb22"}, want: "partner-key holds a comma"},
		{desc: "a key with a trailing newline", keys: []string{"aa11", "bb22\n"}, want: "partner-key-ci holds a comma or whitespace"},
		{desc: "a key with an inner space", keys: []string{"aa 11", "bb22"}, want: "partner-key holds a comma or whitespace"},
	}

	for _, c := range cases {
		t.Run(c.desc, func(t *testing.T) {
			_, err := joinPartnerKeys(c.keys)
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Errorf("joinPartnerKeys() error = %v; want one containing %q", err, c.want)
			}
		})
	}
}
