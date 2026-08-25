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

// Ingot's identity is derived from the region rather than supplied, so the
// region label is the only thing that decides it.
func TestIngotDIDIsNamedAfterTheRegion(t *testing.T) {
	d := &deps{cfg: config{ContentSuffix: "s3.dev.filonecontent.com"}}

	got, err := d.ingotDID("us-east-9")
	if err != nil {
		t.Fatalf("ingotDID: %v", err)
	}
	if want := "did:web:us-east-9.s3.dev.filonecontent.com"; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestIngotDIDRefusesAnUnsetContentSuffix(t *testing.T) {
	d := &deps{cfg: config{}}

	_, err := d.ingotDID("us-east-9")
	if err == nil || !strings.Contains(err.Error(), "FORGE_CONTENT_SUFFIX") {
		t.Fatalf("got %v, want an error naming the variable", err)
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
