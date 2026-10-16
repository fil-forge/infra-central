package main

import (
	"strings"
	"testing"
)

func TestValidateRemovePiriRequestRefuses(t *testing.T) {
	cases := map[string]struct {
		req  Request
		want string
	}{
		"a request without a region":    {Request{PiriDID: "did:key:zPiri"}, "region"},
		"a request without a Piri DID":  {Request{Region: "us-east-9"}, "piri_did"},
		"a Piri DID that is no did:key": {Request{Region: "us-east-9", PiriDID: "did:web:piri.example"}, "piri_did"},
	}

	for desc, tc := range cases {
		t.Run(desc, func(t *testing.T) {
			err := validateRemovePiriRequest(tc.req)
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Errorf("got %v, want a refusal naming %s", err, tc.want)
			}
		})
	}
}

func TestValidateRemovePiriRequestAcceptsARegionAndADIDKey(t *testing.T) {
	if err := validateRemovePiriRequest(Request{Region: "us-east-9", PiriDID: "did:key:zPiri"}); err != nil {
		t.Errorf("got %v, want the request accepted", err)
	}
}
