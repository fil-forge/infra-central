package vaultinit

// CorrelationHeader carries the provision Lambda's request ID on every request
// the function makes to OpenBao. OpenBao generates its own request ID and
// accepts none from a client, so this header is the only way the invocation's
// ID reaches OpenBao's audit log. The name is the one HashiCorp Vault audits by
// default since 1.17; OpenBao audits no header until told to.
const CorrelationHeader = "X-Correlation-Id"
