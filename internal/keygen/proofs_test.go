package keygen

import (
	"encoding/base64"
	"reflect"
	"strings"
	"testing"

	"github.com/fil-forge/ucantone/ucan/delegation"
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

// A textual container is stored as ucantool's CLI writes it, trailing newline
// included. The framing is the one part of a proof that *is* reproducible, and
// consumers depend on it.
func TestIssueProofFollowsTheCLINewlineRule(t *testing.T) {
	issuer, err := GenerateIdentity()
	if err != nil {
		t.Fatalf("GenerateIdentity: %v", err)
	}

	out, err := IssueProof(issuer.PrivatePEM, proofsByName(t)["upload-proof"])
	if err != nil {
		t.Fatalf("IssueProof: %v", err)
	}

	if !strings.HasSuffix(out, "\n") {
		t.Error("the base64+gzip container hilt reads has no trailing newline")
	}
}

// A bare DAG-CBOR delegation is binary, and it travels to the delegator through
// an environment variable, which cannot carry a NUL byte. Storing it verbatim
// leaves the task unable to start at all, with runc naming the variable and
// nothing else, so it is stored base64-encoded instead.
func TestIssueProofEncodesABinaryDelegation(t *testing.T) {
	issuer, err := GenerateIdentity()
	if err != nil {
		t.Fatalf("GenerateIdentity: %v", err)
	}

	out, err := IssueProof(issuer.PrivatePEM, proofsByName(t)["indexing-service-proof"])
	if err != nil {
		t.Fatalf("IssueProof: %v", err)
	}

	decoded, err := base64.StdEncoding.DecodeString(out)
	if err != nil {
		t.Fatalf("stored proof is not base64: %v", err)
	}
	if _, err := delegation.Decode(decoded); err != nil {
		t.Errorf("the delegator cannot parse what the base64 decodes to: %v", err)
	}
}

// The five commands Ingot invokes on hilt, exactly as smelt's generate-proofs.sh
// delegates them. A missing one fails at the request Ingot makes, not at
// onboarding, so the list is worth pinning.
func TestHiltIngotS3ProofCoversEveryCommandIngotInvokes(t *testing.T) {
	proof := HiltIngotS3Proof("appliance/us-east-9", "did:web:hilt.dev.example", "did:key:zIngot")

	want := []string{
		"/s3/request/authorize",
		"/s3/bucket/create",
		"/s3/bucket/delete",
		"/s3/bucket/info",
		"/s3/bucket/list",
	}
	if !reflect.DeepEqual(proof.commands, want) {
		t.Errorf("commands = %v, want %v", proof.commands, want)
	}
}

// Ingot reads the proof from a file, and smelt writes it as a textual container.
func TestHiltIngotS3ProofIsATextualContainer(t *testing.T) {
	issuer, err := GenerateIdentity()
	if err != nil {
		t.Fatalf("GenerateIdentity: %v", err)
	}

	proof := HiltIngotS3Proof("appliance/us-east-9", "did:web:hilt.dev.example", issuer.DID)
	out, err := IssueProof(issuer.PrivatePEM, proof)
	if err != nil {
		t.Fatalf("IssueProof: %v", err)
	}

	if strings.ContainsRune(out, 0) {
		t.Error("the proof carries a NUL byte, so it is not the textual container Ingot reads")
	}
}

func proofsByName(t *testing.T) map[string]Proof {
	t.Helper()

	byName := map[string]Proof{}
	for _, proof := range Proofs(testDIDs(t)) {
		byName[proof.Name] = proof
	}
	return byName
}

// A did map missing a service silently zero-values the DIDs Proofs fills in,
// and ucandelegate would report only an opaque parse error. IssueProof names
// the empty field instead.
func TestIssueProofRejectsAMalformedProof(t *testing.T) {
	issuer, err := GenerateIdentity()
	if err != nil {
		t.Fatalf("GenerateIdentity: %v", err)
	}

	breakages := map[string]func(*Proof){
		"missing issuer DID":   func(p *Proof) { p.issuerDID = "" },
		"missing audience DID": func(p *Proof) { p.audience = "" },
		"missing subject DID":  func(p *Proof) { p.subject = "" },
		"missing commands":     func(p *Proof) { p.commands = nil },
	}

	for want, breakProof := range breakages {
		t.Run(want, func(t *testing.T) {
			proof := Proofs(testDIDs(t))[0]
			breakProof(&proof)

			_, err := IssueProof(issuer.PrivatePEM, proof)
			if err == nil || !strings.Contains(err.Error(), want) {
				t.Errorf("got error %v, want one containing %q", err, want)
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
