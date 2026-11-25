package vaultinit

import (
	"context"
	"fmt"
	"strings"

	"github.com/openbao/openbao/api/v2"
)

// CorrelationHeader carries the provision Lambda's request ID on every request
// the function makes to OpenBao. OpenBao generates its own request ID and
// accepts none from a client, so this header is the only way the invocation's
// ID reaches OpenBao's audit log. The name is the one HashiCorp Vault audits by
// default since 1.17; OpenBao audits no header until told to.
const CorrelationHeader = "X-Correlation-Id"

// correlationHeaderAuditPath registers CorrelationHeader for auditing.
// OpenBao matches header names without regard to case and stores them
// lowercased.
var correlationHeaderAuditPath = "sys/config/auditing/request-headers/" + strings.ToLower(CorrelationHeader)

// EnsureCorrelationHeaderAudited makes OpenBao's audit log record
// CorrelationHeader in each entry's request.headers. The value is a Lambda
// request ID, which is no secret, so it is recorded in the clear: a hashed
// value could not be searched for.
//
// The setting lives in OpenBao's storage and has no place in the server's
// config file, so a phase sets it. Writing it again is harmless, so it is
// written unconditionally. The call needs a sudo-capable token, the root token
// in practice.
func EnsureCorrelationHeaderAudited(ctx context.Context, client *api.Client) error {
	if _, err := client.Logical().WriteWithContext(ctx, correlationHeaderAuditPath, map[string]any{"hmac": false}); err != nil {
		return fmt.Errorf("audit the %s header: %w", CorrelationHeader, err)
	}
	return nil
}
