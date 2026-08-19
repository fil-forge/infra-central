package keygen

import (
	"bytes"
	"encoding/base64"
	"fmt"

	"github.com/fil-forge/ucantool/pkg/ucandelegate"
)

// Proof is a UCAN delegation a service needs at startup.
//
// Proofs are not secrets. A delegation is a signed statement that one DID may
// invoke a command on another, and it is useless without the audience's own
// key, which is why smelt commits these to git and this project stores them as
// plaintext SSM parameters.
//
// They are filed under the service that *reads* them rather than the one that
// signs them, so each task's execution role still needs only its own prefix.
type Proof struct {
	// Consumer is the SSM service prefix the proof is stored under.
	Consumer string
	// Name is the parameter name under that prefix.
	Name string
	// Issuer is the service whose identity key signs the delegation.
	Issuer string

	issuerDID string
	audience  string
	subject   string
	commands  []string
	codec     string // "" is a bare DAG-CBOR delegation; otherwise a container
}

// Proofs returns the delegations this deployment needs, given the did:web of
// each service.
//
// Three of smelt's five apply here. The piri-0 and hilt-ingot proofs belong to
// the storage-node side of the stack, which this project does not deploy.
//
// The first two exist only to satisfy the delegator's startup validation: it
// requires an indexing-service and an egress-tracking delegation even though
// neither service runs yet. That is why their identity keys are minted at all.
func Proofs(did map[string]string) []Proof {
	return []Proof{
		{
			Consumer:  "delegator",
			Name:      "indexing-service-proof",
			Issuer:    "indexer",
			issuerDID: did["indexer"],
			audience:  did["delegator"],
			subject:   did["indexer"],
			commands:  []string{"/claim/cache"},
		},
		{
			Consumer:  "delegator",
			Name:      "egress-tracking-proof",
			Issuer:    "etracker",
			issuerDID: did["etracker"],
			audience:  did["delegator"],
			subject:   did["etracker"],
			commands:  []string{"/egress/track"},
		},
		// hilt presents this to sprue when registering tenants as customers.
		// hilt's loader parses a UCAN *container*, not a bare delegation, hence
		// the codec.
		{
			Consumer:  "hilt",
			Name:      "upload-proof",
			Issuer:    "sprue",
			issuerDID: did["sprue"],
			audience:  did["hilt"],
			subject:   did["sprue"],
			commands:  []string{"/customer/add"},
			codec:     "base64+gzip",
		},
	}
}

// IssueProof signs a delegation with the issuer's private key and returns it in
// the form it is stored in.
//
// A bare DAG-CBOR delegation is binary, and every proof reaches its consumer as
// an environment variable that the task's entrypoint writes to a file. An
// environment variable cannot carry a NUL byte: the container never starts, and
// runc reports only the variable name. Binary proofs are therefore stored
// base64-encoded, and the entrypoint decodes them.
//
// A textual container needs no encoding, and its bytes match what `ucantool
// delegate` writes, down to the trailing newline that ucandelegate.Result adds
// for a printable codec. That keeps such a proof byte-identical to one smelt
// committed.
//
// The key is passed as PEM bytes rather than a path on purpose: the file-based
// API would mean writing a private key to the Lambda's /tmp to satisfy a
// signature.
func IssueProof(issuerPEM []byte, proof Proof) (string, error) {
	if err := validateProof(proof); err != nil {
		return "", err
	}

	result, err := ucandelegate.IssueFromPEM(issuerPEM, ucandelegate.Request{
		IssuerDIDWeb:   proof.issuerDID,
		Audience:       proof.audience,
		Subject:        proof.subject,
		Commands:       proof.commands,
		ContainerCodec: proof.codec,
		// No expiration: these authorise startup-time capabilities between
		// services we operate, and an expiry would take a service down at a
		// time nobody chose. smelt makes the same call.
	})
	if err != nil {
		return "", fmt.Errorf("issue %s proof for %s: %w", proof.Name, proof.Consumer, err)
	}

	if !result.IsText() {
		return base64.StdEncoding.EncodeToString(result.Bytes), nil
	}

	var out bytes.Buffer
	if _, err := result.WriteTo(&out); err != nil {
		return "", fmt.Errorf("encode %s proof: %w", proof.Name, err)
	}
	return out.String(), nil
}

// validateProof rejects a proof with a missing DID or command list before it
// reaches ucandelegate, where a zero-value field would surface as an opaque
// parse error. The usual cause is a did map handed to Proofs without an entry
// for every service.
func validateProof(proof Proof) error {
	missing := ""
	switch {
	case proof.issuerDID == "":
		missing = "issuer DID"
	case proof.audience == "":
		missing = "audience DID"
	case proof.subject == "":
		missing = "subject DID"
	case len(proof.commands) == 0:
		missing = "commands"
	default:
		return nil
	}
	return fmt.Errorf("%s proof for %s: missing %s", proof.Name, proof.Consumer, missing)
}
