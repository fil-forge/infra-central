package onboard

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"strings"

	hiltclient "github.com/fil-forge/hilt/pkg/client"
	"github.com/fil-forge/ucantone/did"
	"github.com/fil-forge/ucantone/ucan"
	"github.com/jackc/pgx/v5"
	"go.uber.org/zap"
)

// HiltClient adapts hilt's admin client, and reads its database to verify what
// that client did.
//
// The database read is not belt and braces. hilt raises one error,
// ErrProviderExists, for a DID already registered under this region and for one
// registered under a different region, and it ships no command to list or move a
// provider. So the row is the only thing that says which region a DID actually
// serves, and reading it is how a region rename is caught instead of silently
// accepted.
type HiltClient struct {
	admin *hiltclient.AdminClient
	dsn   string
}

// NewHiltClient builds the admin client from hilt's did:web and its key, plus
// the DSN for the database behind it.
func NewHiltClient(endpoint, dsn string, issuer ucan.Issuer) (*HiltClient, error) {
	address, err := url.Parse(endpoint)
	if err != nil {
		return nil, fmt.Errorf("parse hilt's endpoint %q: %w", endpoint, err)
	}

	admin, err := hiltclient.NewAdminClient(issuer, *address, zap.NewNop())
	if err != nil {
		return nil, fmt.Errorf("build hilt's admin client: %w", err)
	}
	return &HiltClient{admin: admin, dsn: dsn}, nil
}

// Provider returns hilt's row for a DID, or nil when it has none.
func (c *HiltClient) Provider(ctx context.Context, providerDID string) (*HiltProvider, error) {
	conn, err := pgx.Connect(ctx, c.dsn)
	if err != nil {
		return nil, fmt.Errorf("connect to hilt's database: %w", err)
	}
	defer func() { _ = conn.Close(ctx) }()

	var region string
	var policy *string
	err = conn.QueryRow(ctx, "SELECT region, policy FROM provider WHERE id = $1", providerDID).Scan(&region, &policy)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read hilt's provider row for %s: %w", providerDID, err)
	}
	provider := &HiltProvider{Region: strings.TrimSpace(region)}
	if policy != nil {
		provider.Policy = strings.TrimSpace(*policy)
	}
	return provider, nil
}

// AddProvider registers a DID as the provider for a region, with the storage
// nodes that serve it.
//
// An already-registered DID is tolerated here and checked by the caller, which
// re-reads the row. The error cannot distinguish this region from another one, so
// tolerating it is only safe because nothing trusts it.
func (c *HiltClient) AddProvider(ctx context.Context, providerDID, region string, nodeDIDs []string) error {
	parsed, err := did.Parse(providerDID)
	if err != nil {
		return fmt.Errorf("parse provider DID %q: %w", providerDID, err)
	}
	nodes, err := parseNodeDIDs(nodeDIDs)
	if err != nil {
		return err
	}

	err = c.admin.AddProvider(ctx, parsed, region, nodes)
	if err == nil || isAlreadyRegistered(err) {
		return nil
	}
	return fmt.Errorf("add %s for region %s: %w", providerDID, region, err)
}

// SetProviderNodes replaces the storage nodes a registered provider serves
// with. hilt holds no node list of its own: the set lives in the routing policy
// it manages on sprue, so the caller has to send the whole set every time.
func (c *HiltClient) SetProviderNodes(ctx context.Context, providerDID string, nodeDIDs []string) error {
	parsed, err := did.Parse(providerDID)
	if err != nil {
		return fmt.Errorf("parse provider DID %q: %w", providerDID, err)
	}
	nodes, err := parseNodeDIDs(nodeDIDs)
	if err != nil {
		return err
	}

	if err := c.admin.SetProviderNodes(ctx, parsed, nodes); err != nil {
		return fmt.Errorf("set %s's storage nodes: %w", providerDID, err)
	}
	return nil
}

func parseNodeDIDs(nodeDIDs []string) ([]did.DID, error) {
	nodes := make([]did.DID, 0, len(nodeDIDs))
	for _, n := range nodeDIDs {
		parsed, err := did.Parse(n)
		if err != nil {
			return nil, fmt.Errorf("parse node DID %q: %w", n, err)
		}
		nodes = append(nodes, parsed)
	}
	return nodes, nil
}

func isAlreadyRegistered(err error) bool {
	return strings.Contains(strings.ToLower(err.Error()), "already registered")
}
