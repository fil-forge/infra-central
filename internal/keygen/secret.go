package keygen

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
)

// secretBytes is the entropy behind every generated connection secret. 24 bytes
// renders as 48 hex characters.
const secretBytes = 24

// RandomHex returns a hex-only random secret.
//
// Hex-only is a deliberate constraint rather than a stylistic one. These values
// land unquoted inside Postgres connection strings and inside JSON blobs such
// as plc's DB_CREDS_JSON, where a quote or a backslash would break the
// consumer. Restricting the alphabet to [0-9a-f] removes the escaping problem
// instead of solving it.
func RandomHex() (string, error) {
	b := make([]byte, secretBytes)
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("read random bytes: %w", err)
	}
	return hex.EncodeToString(b), nil
}
