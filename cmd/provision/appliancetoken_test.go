package main

import "testing"

// Minting is the only operation in this project that is not idempotent, so what
// it does when a region already has an accessor on record is worth pinning.
func TestDecideTokenAction(t *testing.T) {
	cases := []struct {
		desc      string
		tokenLive bool
		reissue   bool
		want      string
	}{
		{
			desc: "the recorded token has lapsed",
			want: tokenActionMint,
		},
		{
			desc:    "the recorded token has lapsed and reissue was asked for anyway",
			reissue: true,
			want:    tokenActionMint,
		},
		{
			desc:      "the recorded token is live",
			tokenLive: true,
			want:      tokenActionRefuse,
		},
		{
			desc:      "the recorded token is live and reissue was asked for",
			tokenLive: true,
			reissue:   true,
			want:      tokenActionReissue,
		},
	}

	for _, c := range cases {
		t.Run(c.desc, func(t *testing.T) {
			if got := decideTokenAction(c.tokenLive, c.reissue); got != c.want {
				t.Errorf("decideTokenAction(%v, %v) = %q, want %q", c.tokenLive, c.reissue, got, c.want)
			}
		})
	}
}
