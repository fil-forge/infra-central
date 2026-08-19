package keygen

import (
	"fmt"

	"github.com/fil-forge/ucantone/multikey"
	"github.com/fil-forge/ucantone/multikey/ed25519"
	"github.com/fil-forge/ucantool/pkg/identity"
)

// The PEM helpers come from ucantool rather than libforge, which exports an
// identical pair. libforge's EncodeSignerToPEM formats the signer itself into
// its error text, and an ed25519 signer is a []byte with no String method, so a
// marshalling failure would render the raw private key into an error this
// Lambda logs. ucantool's version formats the key DID instead.

// Identity is an Ed25519 service identity in every serialization the Forge
// services accept. smelt writes these to files on a VM; here they are held in
// memory and handed to the SSM store, so nothing but the returned DID ever
// leaves the process.
//
// The two private serializations exist because the services disagree: hilt and
// swarf read a PEM file, while the delegator and signing service take the
// multibase form inline as an environment variable. Unifying the formats is
// tracked in https://linear.app/filecoin-foundation/issue/FIL-1061.
//
// There is no public-key serialization because no service asks for one. The
// DID carries the public key, and a consumer that needs the raw bytes decodes
// them from it.
type Identity struct {
	PrivatePEM []byte // PKCS#8 PEM, the "PRIVATE KEY" block — SECRET
	Multibase  string // Base64pad multibase private key — SECRET
	DID        string // did:key derived from the public key
}

// GenerateIdentity mints a new Ed25519 service identity.
func GenerateIdentity() (*Identity, error) {
	signer, err := ed25519.Generate()
	if err != nil {
		return nil, fmt.Errorf("generate ed25519 key: %w", err)
	}
	return newIdentity(signer)
}

// ParseIdentity reconstructs an identity from a stored PKCS#8 PEM. This is the
// idempotent path: when a key already exists in SSM the provision Lambda reads
// it back and re-derives the public material rather than minting a new one.
func ParseIdentity(privatePEM []byte) (*Identity, error) {
	signer, err := identity.DecodeSignerFromPEM(privatePEM)
	if err != nil {
		return nil, fmt.Errorf("decode private key PEM: %w", err)
	}
	return newIdentity(signer)
}

func newIdentity(signer multikey.Signer) (*Identity, error) {
	privatePEM, err := identity.EncodeSignerToPEM(signer)
	if err != nil {
		return nil, fmt.Errorf("encode private key PEM: %w", err)
	}

	return &Identity{
		PrivatePEM: privatePEM,
		Multibase:  multikey.FormatSigner(signer),
		DID:        multikey.KeyIssuer(signer).DID().String(),
	}, nil
}
