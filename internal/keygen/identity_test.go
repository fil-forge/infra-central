package keygen

import (
	"strings"
	"testing"

	"github.com/fil-forge/ucantone/multikey/ed25519"
)

func TestGenerateIdentityDerivesAKeyDID(t *testing.T) {
	id, err := GenerateIdentity()
	if err != nil {
		t.Fatalf("GenerateIdentity: %v", err)
	}
	if !strings.HasPrefix(id.DID, "did:key:") {
		t.Errorf("DID = %q, want a did:key", id.DID)
	}
}

// The idempotent path in the provision Lambda reads a stored PEM back and
// re-derives the public material. If that derivation disagreed with the
// original, a re-apply would report a different DID for an unchanged key.
func TestParseIdentityRecoversTheSameDID(t *testing.T) {
	original, err := GenerateIdentity()
	if err != nil {
		t.Fatalf("GenerateIdentity: %v", err)
	}

	parsed, err := ParseIdentity(original.PrivatePEM)
	if err != nil {
		t.Fatalf("ParseIdentity: %v", err)
	}

	if parsed.DID != original.DID {
		t.Errorf("DID after round trip = %q, want %q", parsed.DID, original.DID)
	}
}

func TestParseIdentityRecoversTheSameMultibaseKey(t *testing.T) {
	original, err := GenerateIdentity()
	if err != nil {
		t.Fatalf("GenerateIdentity: %v", err)
	}

	parsed, err := ParseIdentity(original.PrivatePEM)
	if err != nil {
		t.Fatalf("ParseIdentity: %v", err)
	}

	if parsed.Multibase != original.Multibase {
		t.Errorf("multibase key after round trip = %q, want %q", parsed.Multibase, original.Multibase)
	}
}

// The delegator and signing service take the key inline as an environment
// variable and parse it with this exact function, so a multibase form they
// cannot read would only fail at task startup.
func TestMultibaseKeyIsReadableByTheServices(t *testing.T) {
	id, err := GenerateIdentity()
	if err != nil {
		t.Fatalf("GenerateIdentity: %v", err)
	}

	if _, err := ed25519.Parse(id.Multibase); err != nil {
		t.Errorf("ed25519.Parse(multibase) failed: %v", err)
	}
}

func TestIdentityPEMBlocksAreLabelledForTheServices(t *testing.T) {
	id, err := GenerateIdentity()
	if err != nil {
		t.Fatalf("GenerateIdentity: %v", err)
	}

	blocks := map[string]struct {
		pem  []byte
		want string
	}{
		"private key": {pem: id.PrivatePEM, want: "-----BEGIN PRIVATE KEY-----"},
		"public key":  {pem: id.PublicPEM, want: "-----BEGIN PUBLIC KEY-----"},
	}

	for name, block := range blocks {
		t.Run(name, func(t *testing.T) {
			if !strings.HasPrefix(string(block.pem), block.want) {
				t.Errorf("PEM does not start with %q", block.want)
			}
		})
	}
}
