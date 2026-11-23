package main

import (
	"fmt"

	"github.com/openbao/openbao/api/v2"

	"github.com/fil-forge/infra-central/internal/vaultinit"
)

// openBaoClient builds the client every phase reaches central OpenBao with.
func (d *deps) openBaoClient() (*api.Client, error) {
	return newOpenBaoClient(&api.Config{Address: d.cfg.OpenBaoAddr}, d.requestID)
}

// newOpenBaoClient builds an OpenBao client that sends the invocation's request
// ID with every request, so OpenBao's audit log names the invocation that made
// it. A clone sends it too: vaultinit clones the client to probe OpenBao and to
// unwrap tokens, and a clone drops the headers unless the config says
// otherwise. Without a request ID, outside Lambda, it sends no header.
func newOpenBaoClient(cfg *api.Config, requestID string) (*api.Client, error) {
	cfg.CloneHeaders = true
	client, err := api.NewClient(cfg)
	if err != nil {
		return nil, fmt.Errorf("build openbao client: %w", err)
	}
	if requestID != "" {
		headers := client.Headers()
		headers.Set(vaultinit.CorrelationHeader, requestID)
		client.SetHeaders(headers)
	}
	return client, nil
}
