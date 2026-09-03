package main

import (
	"bytes"
	"strings"
	"testing"
)

// The proof reaches the Lambda in one of two fields, and the binary form only
// survives the trip because the script encodes it. What each field decodes to is
// worth pinning.
func TestDecodePiriProof(t *testing.T) {
	cases := []struct {
		desc string
		req  Request
		want []byte
	}{
		{
			desc: "a textual container sent as it was pasted",
			req:  Request{PiriProof: "uOqJlcm9vdHOA"},
			want: []byte("uOqJlcm9vdHOA"),
		},
		{
			desc: "binary bytes the script encoded",
			req:  Request{PiriProofB64: "AAECA/8="},
			want: []byte{0x00, 0x01, 0x02, 0x03, 0xff},
		},
		{
			desc: "neither field, which the plan reports as a blocker",
			req:  Request{},
			want: []byte{},
		},
	}

	for _, c := range cases {
		t.Run(c.desc, func(t *testing.T) {
			got, err := decodePiriProof(c.req)
			if err != nil {
				t.Fatalf("decodePiriProof: %v", err)
			}
			if !bytes.Equal(got, c.want) {
				t.Errorf("got %q, want %q", got, c.want)
			}
		})
	}
}

// Ingot's RFC identity is derived from both its region and stage.
func TestIngotDIDIsNamedAfterTheRegionAndStage(t *testing.T) {
	d := &deps{cfg: config{IngotHostnameSuffix: "latest.dev.filonecontent.com"}}

	got, err := d.ingotDID("us-east-9")
	if err != nil {
		t.Fatalf("ingotDID: %v", err)
	}
	if want := "did:web:s3.us-east-9.latest.dev.filonecontent.com"; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestServiceHostnamesUseStableIdentityLabels(t *testing.T) {
	d := &deps{cfg: config{HostnameSuffix: "latest.dev.fil-forge.com"}}
	want := map[string]string{
		"sprue":           "upload.latest.dev.fil-forge.com",
		"hilt":            "auth.latest.dev.fil-forge.com",
		"swarf":           "revoke.latest.dev.fil-forge.com",
		"delegator":       "delegator.latest.dev.fil-forge.com",
		"signing-service": "signer.latest.dev.fil-forge.com",
		"indexer":         "indexer.latest.dev.fil-forge.com",
	}
	for service, hostname := range want {
		if got := d.serviceHostname(service); got != hostname {
			t.Errorf("%s: got %q, want %q", service, got, hostname)
		}
	}
}

// A caller working from the old contract sent the appliance's Ingot DID. Being
// told the input is gone beats having it silently ignored.
func TestValidateOnboardRequestRefusesASuppliedIngotDID(t *testing.T) {
	err := validateOnboardRequest(Request{
		Region:   "us-east-9",
		PiriDID:  "did:key:zPiri",
		PiriURL:  "https://piri.example",
		IngotDID: "did:key:zIngot",
	})
	if err == nil || !strings.Contains(err.Error(), "ingot_did") {
		t.Fatalf("got %v, want a refusal naming the field", err)
	}
}

func TestValidateOnboardRequestRefusesANonKeyPiriDID(t *testing.T) {
	err := validateOnboardRequest(Request{
		Region:  "us-east-9",
		PiriDID: "did:web:piri.example",
		PiriURL: "https://piri.example",
	})
	if err == nil || !strings.Contains(err.Error(), "piri_did") {
		t.Fatalf("got %v, want a refusal naming the field", err)
	}
}

func TestDecodePiriProofRefusesBothFields(t *testing.T) {
	_, err := decodePiriProof(Request{PiriProof: "text", PiriProofB64: "AAEC"})
	if err == nil || !strings.Contains(err.Error(), "not both") {
		t.Fatalf("got %v, want a refusal naming both fields", err)
	}
}

func TestDecodePiriProofRefusesUndecodableBase64(t *testing.T) {
	_, err := decodePiriProof(Request{PiriProofB64: "not base64!"})
	if err == nil || !strings.Contains(err.Error(), "piri_proof_b64") {
		t.Fatalf("got %v, want an error naming the field", err)
	}
}
