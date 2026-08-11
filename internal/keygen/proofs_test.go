package keygen

import (
	"strings"
	"testing"
)

func testDIDs(t *testing.T) map[string]string {
	t.Helper()

	dids := map[string]string{}
	for _, service := range []string{"sprue", "hilt", "delegator", "indexer", "etracker"} {
		dids[service] = "did:web:" + service + ".dev.example"
	}
	return dids
}

func TestProofsCoverTheStartupDelegations(t *testing.T) {
	got := map[string]string{}
	for _, proof := range Proofs(testDIDs(t)) {
		got[proof.Consumer+"/"+proof.Name] = proof.Issuer
	}

	want := map[string]string{
		"delegator/indexing-service-proof": "indexer",
		"delegator/egress-tracking-proof":  "etracker",
		"hilt/upload-proof":                "sprue",
	}

	if len(got) != len(want) {
		t.Fatalf("got %d proofs, want %d: %v", len(got), len(want), got)
	}
	for key, issuer := range want {
		if got[key] != issuer {
			t.Errorf("%s is issued by %q, want %q", key, got[key], issuer)
		}
	}
}

// A proof is signed by the issuer's key, so every issuer named above must be a
// service whose identity the seed phase actually mints. Naming one it does not
// would fail at apply time with a missing-parameter error.
func TestProofIssuersHaveIdentities(t *testing.T) {
	dids := testDIDs(t)

	for _, proof := range Proofs(dids) {
		t.Run(proof.Name, func(t *testing.T) {
			if _, ok := dids[proof.Issuer]; !ok {
				t.Errorf("issuer %q has no identity", proof.Issuer)
			}
		})
	}
}

// Delegations are public but not reproducible: ucantone mints a random nonce
// per delegation, so signing the same request twice yields different bytes and
// a different CID.
//
// This is why proofs go through EnsurePublic rather than being rewritten on
// every apply like DIDs and addresses are. Anyone tempted to simplify that back
// to an unconditional write should see this test fail first.
func TestIssueProofIsNotReproducible(t *testing.T) {
	issuer, err := GenerateIdentity()
	if err != nil {
		t.Fatalf("GenerateIdentity: %v", err)
	}
	proof := Proofs(testDIDs(t))[0]

	first, err := IssueProof(issuer.PrivatePEM, proof)
	if err != nil {
		t.Fatalf("IssueProof: %v", err)
	}
	second, err := IssueProof(issuer.PrivatePEM, proof)
	if err != nil {
		t.Fatalf("IssueProof: %v", err)
	}

	if first == second {
		t.Error("two delegations from the same input were identical; if ucantone dropped its per-delegation nonce, proofs could be rewritten freely and EnsurePublic is no longer needed")
	}
}

// ucantool's CLI writes textual container codecs with a trailing newline and
// raw codecs without one. The framing is the one part of a proof that *is*
// reproducible, and consumers depend on it.
func TestIssueProofFollowsTheCLINewlineRule(t *testing.T) {
	issuer, err := GenerateIdentity()
	if err != nil {
		t.Fatalf("GenerateIdentity: %v", err)
	}

	cases := map[string]struct {
		proofName    string
		wantsNewline bool
	}{
		"raw delegation, read by the delegator": {
			proofName:    "indexing-service-proof",
			wantsNewline: false,
		},
		"base64+gzip container, read by hilt": {
			proofName:    "upload-proof",
			wantsNewline: true,
		},
	}

	proofs := map[string]Proof{}
	for _, proof := range Proofs(testDIDs(t)) {
		proofs[proof.Name] = proof
	}

	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			out, err := IssueProof(issuer.PrivatePEM, proofs[tc.proofName])
			if err != nil {
				t.Fatalf("IssueProof: %v", err)
			}
			if got := strings.HasSuffix(out, "\n"); got != tc.wantsNewline {
				t.Errorf("trailing newline = %v, want %v", got, tc.wantsNewline)
			}
		})
	}
}

func TestIssueProofRejectsAKeyItCannotRead(t *testing.T) {
	proof := Proofs(testDIDs(t))[0]

	if _, err := IssueProof([]byte("not a PEM file"), proof); err == nil {
		t.Error("IssueProof accepted something that is not a private key")
	}
}
