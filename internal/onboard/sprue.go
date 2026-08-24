package onboard

import (
	"context"
	"fmt"
	"net/url"

	sprueclient "github.com/fil-forge/sprue/pkg/client"
	"github.com/fil-forge/ucantone/did"
	"github.com/fil-forge/ucantone/ucan"
	"github.com/fil-forge/ucantone/ucan/container"
	"go.uber.org/zap"
)

// SprueClient adapts sprue's published admin client.
//
// The client is sprue's own, so the invocation format cannot drift from what
// sprue accepts. It signs as sprue: an admin invocation is refused unless the
// issuer DID equals sprue's service DID, which is why this needs sprue's own
// identity key rather than a credential of its own.
type SprueClient struct {
	client *sprueclient.Client
}

// NewSprueClient builds the admin client from sprue's did:web and its key.
func NewSprueClient(serviceDIDWeb, endpoint string, issuer ucan.Issuer) (*SprueClient, error) {
	serviceDID, err := did.Parse(serviceDIDWeb)
	if err != nil {
		return nil, fmt.Errorf("parse sprue's DID %q: %w", serviceDIDWeb, err)
	}

	address, err := url.Parse(endpoint)
	if err != nil {
		return nil, fmt.Errorf("parse sprue's endpoint %q: %w", endpoint, err)
	}

	// zap.NewNop rather than a configured logger: the client logs invocation
	// bodies, and this Lambda's own slog lines already say what it is doing.
	client, err := sprueclient.New(serviceDID, address, issuer, zap.NewNop())
	if err != nil {
		return nil, fmt.Errorf("build sprue's admin client: %w", err)
	}
	return &SprueClient{client: client}, nil
}

// Provider returns sprue's record for a DID, or nil when it has none.
func (c *SprueClient) Provider(ctx context.Context, providerDID string) (*Provider, error) {
	// sprue has no read for one provider, so the list is filtered here. It holds
	// one entry per region, so there is nothing to paginate.
	list, _, err := c.client.AdminProviderList(ctx)
	if err != nil {
		return nil, fmt.Errorf("list sprue's providers: %w", err)
	}
	if list == nil {
		return nil, nil
	}

	for _, provider := range list.Providers {
		if provider.Provider.String() != providerDID {
			continue
		}
		return &Provider{
			Endpoint:          provider.Endpoint,
			Weight:            provider.Weight,
			ReplicationWeight: provider.ReplicationWeight,
		}, nil
	}
	return nil, nil
}

// Register adds a provider, presenting the delegation the appliance signed.
func (c *SprueClient) Register(ctx context.Context, providerDID, endpoint string, proof []byte) error {
	parsed, err := did.Parse(providerDID)
	if err != nil {
		return fmt.Errorf("parse provider DID %q: %w", providerDID, err)
	}

	// The appliance sends its proof in whatever container ucantool wrote. Decode
	// picks the codec out of the bytes, so the appliance is free to send the
	// textual form a person can paste or the binary one a tool produces.
	proofs, err := container.Decode(proof)
	if err != nil {
		return fmt.Errorf("decode the appliance's Piri proof: %w", err)
	}

	if _, err := c.client.AdminProviderRegister(ctx, parsed, endpoint, proofs); err != nil {
		return fmt.Errorf("register %s: %w", providerDID, err)
	}
	return nil
}

// SetWeight sets a provider's scheduling and replication weights.
func (c *SprueClient) SetWeight(ctx context.Context, providerDID string, weight, replicationWeight int) error {
	parsed, err := did.Parse(providerDID)
	if err != nil {
		return fmt.Errorf("parse provider DID %q: %w", providerDID, err)
	}

	if _, err := c.client.AdminProviderWeightSet(ctx, parsed, weight, replicationWeight); err != nil {
		return fmt.Errorf("set %s's weights: %w", providerDID, err)
	}
	return nil
}
