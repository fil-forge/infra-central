// Command provision mints every secret a Forge stage needs and seeds its
// databases, running as a Lambda inside the VPC.
//
// It exists so that private keys are generated where they will be used rather
// than on an operator's laptop. The platform stack invokes it and receives only
// public identifiers: DIDs, wallet addresses, and the names of what was created.
// No private key ever enters stack state, and nothing is written to a local disk
// anywhere in the flow.
//
// Two phases, because the ordering is circular otherwise. OpenBao stores its
// data in Postgres, so its database must exist before it starts; but OpenBao
// must be running before it can be configured. Phase seed runs after RDS and
// before OpenBao; phase vault runs once OpenBao is serving.
package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"time"

	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/aws/ratelimit"
	"github.com/aws/aws-sdk-go-v2/aws/retry"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/secretsmanager"
	"github.com/aws/aws-sdk-go-v2/service/ssm"

	"github.com/fil-forge/infra-central/internal/fund"
	"github.com/fil-forge/infra-central/internal/ssmstore"
)

// Request is the event the platform stack sends through its Lambda invocation.
type Request struct {
	Phase string `json:"phase"`
	// Trigger is ignored by the handler. It exists so a caller can force a
	// re-invocation by changing the input, which is how the invocation resource
	// decides whether to call again.
	Trigger string `json:"trigger,omitempty"`

	// --- fund phase only ---

	// Confirm must be true before the fund phase signs anything. Without it the
	// phase reports its plan and stops, so no invocation moves money by
	// accident.
	Confirm bool `json:"confirm,omitempty"`

	// Amounts are decimal USDFC strings exactly as the operator typed them, so
	// the number shown in the confirmation prompt is the number that is signed.
	// Empty means the default.
	Deposit         string `json:"deposit,omitempty"`
	LockupAllowance string `json:"lockup_allowance,omitempty"`
	RateAllowance   string `json:"rate_allowance,omitempty"`
	MaxLockupPeriod uint64 `json:"max_lockup_period,omitempty"`
	ForceDeposit    bool   `json:"force_deposit,omitempty"`
}

// Response carries public material back into stack state. Every field here is
// safe to read by anyone with state access, which is the point.
type Response struct {
	Phase string `json:"phase"`

	// DIDs maps a service name to its did:key.
	DIDs map[string]string `json:"dids,omitempty"`
	// Addresses maps a wallet name to its EIP-55 address, the value to fund.
	Addresses map[string]string `json:"addresses,omitempty"`
	// Databases lists the Postgres databases now present.
	Databases []string `json:"databases,omitempty"`
	// Created lists parameters this invocation minted. On a steady-state apply
	// it is empty, which is the signal that nothing was regenerated.
	Created []string `json:"created"`

	// Initialised reports whether this invocation initialised OpenBao.
	Initialised bool `json:"initialised,omitempty"`

	// DryRun is true when the fund phase reported a plan without signing.
	DryRun     bool         `json:"dry_run,omitempty"`
	FundPlan   *fund.Plan   `json:"fund_plan,omitempty"`
	FundResult *fund.Result `json:"fund_result,omitempty"`
}

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stderr, nil)))
	lambda.Start(handle)
}

func handle(ctx context.Context, req Request) (*Response, error) {
	cfg, err := loadConfig()
	if err != nil {
		return nil, err
	}

	awsCfg, err := awsconfig.LoadDefaultConfig(ctx)
	if err != nil {
		return nil, fmt.Errorf("load AWS config: %w", err)
	}

	deps := &deps{
		cfg:     cfg,
		store:   ssmstore.New(ssm.NewFromConfig(awsCfg, throttleTolerantRetries), cfg.Stage),
		secrets: secretsmanager.NewFromConfig(awsCfg),
	}

	// Every log line here announces the step about to start, never the one
	// that just finished. A phase fails by hanging at least as often as it
	// fails by returning an error, and the last line of a hung invocation
	// should name what it is stuck on rather than the last thing that worked.
	//
	// The phase is logged first because all three share one log group, and
	// without this line a stream gives no clue which one it belongs to.
	slog.Info("starting phase", "phase", req.Phase, "stage", cfg.Stage)

	switch req.Phase {
	case "seed":
		return deps.seed(ctx)
	case "vault":
		return deps.vault(ctx)
	case "fund":
		return deps.fund(ctx, req)
	default:
		return nil, fmt.Errorf("unknown phase %q; want \"seed\", \"vault\" or \"fund\"", req.Phase)
	}
}

// throttleTolerantRetries slows the SSM client down to the write quota instead
// of failing the invocation.
//
// PutParameter is capped at 3 transactions per second on standard throughput,
// and the seed phase writes dozens of parameters back to back, so a first apply
// is throttled by design. The SDK's default retryer gives up after three
// attempts with sub-second backoff, which is not enough to wait out a quota
// this small. Adaptive mode adds a client-side rate limiter that learns the
// real rate from the throttling responses, so the burst is paced rather than
// retried blindly.
func throttleTolerantRetries(o *ssm.Options) {
	o.Retryer = retry.NewAdaptiveMode(func(ao *retry.AdaptiveModeOptions) {
		ao.StandardOptions = append(ao.StandardOptions, func(so *retry.StandardOptions) {
			so.MaxAttempts = 10
			so.MaxBackoff = 10 * time.Second
			// The default token bucket stops retrying once a run has spent its
			// budget, which is the wrong trade here: the Lambda has a 600s
			// timeout and nothing else competing for the quota.
			so.RateLimiter = ratelimit.None
		})
	})
}

// deps is what both phases need: configuration and the two AWS clients.
type deps struct {
	cfg     config
	store   *ssmstore.Store
	secrets *secretsmanager.Client
}
