package main

import "fmt"

// Public service labels are part of the stable Forge service identities. The
// implementation names remain useful for SSM paths and logs, but must not leak
// into did:web identifiers.
var serviceHostnameLabels = map[string]string{
	"sprue":           "upload",
	"hilt":            "auth",
	"swarf":           "revoke",
	"delegator":       "delegator",
	"signing-service": "signer",
}

func (d *deps) serviceHostname(service string) string {
	label := serviceHostnameLabels[service]
	if label == "" {
		label = service
	}
	return fmt.Sprintf("%s.%s", label, d.cfg.HostnameSuffix)
}
