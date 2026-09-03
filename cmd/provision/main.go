// Command provision mints every secret a Forge stage needs and seeds its
// databases, running as a Lambda inside the VPC.
//
// It exists so that private keys are generated where they will be used rather
// than on an operator's laptop. Terraform invokes it and receives only public
// identifiers: DIDs, wallet addresses, and the names of what was created. No
// private key ever enters Terraform state, and nothing is written to a local
// disk anywhere in the flow.
//
// Terraform drives two phases, because the ordering is circular otherwise.
// OpenBao stores its data in Postgres, so its database must exist before it
// starts; but OpenBao must be running before it can be configured. Phase seed
// runs after RDS and before OpenBao; phase vault runs once OpenBao is serving.
//
// Four more phases exist that Terraform must never invoke, because an apply must
// not move money, issue a credential or delete a registration. Phase fund
// deposits USDFC for the payer, appliance-token mints a regional appliance's
// unseal credential, onboard admits an appliance and retire removes a region's
// Ingot identity so it can be admitted again under a different DID. All four are
// run by an operator through a script that shows the plan and asks first.
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
	"github.com/fil-forge/infra-central/internal/onboard"
	"github.com/fil-forge/infra-central/internal/ssmstore"
)

// Request is the event Terraform sends through aws_lambda_invocation.
type Request struct {
	Phase string `json:"phase"`
	// Trigger is ignored by the handler. It exists so a caller can force a
	// re-invocation by changing the input, which is how aws_lambda_invocation
	// decides whether to call again.
	Trigger string `json:"trigger,omitempty"`

	// --- vault phase only ---

	// ApplianceRegions and RetiredApplianceRegions are the region labels this
	// stage seals appliances for, and the ones it has retired. Both come from
	// committed tfvars, so they reach the phase through the invocation input and
	// changing either re-invokes on their own. Git is the source of truth: the
	// phase reconciles OpenBao against these two lists and refuses to touch a
	// key that neither one names.
	ApplianceRegions        []string `json:"appliance_regions,omitempty"`
	RetiredApplianceRegions []string `json:"retired_appliance_regions,omitempty"`

	// --- appliance-token and retire phases ---

	// Region is the appliance's region label, naming its transit key and policy
	// for the appliance-token phase, and the provider row and parameter prefix
	// for retire.
	Region string `json:"region,omitempty"`

	// --- appliance-token phase only ---

	// NodeCIDR is the node's egress address, its Elastic IP as a /32. The token
	// is bound to it and is worthless anywhere else.
	NodeCIDR string `json:"node_cidr,omitempty"`
	// Period and WrapTTL override the defaults in appliancetoken.go.
	Period  string `json:"period,omitempty"`
	WrapTTL string `json:"wrap_ttl,omitempty"`
	// Reissue revokes the region's existing token before minting another.
	// Without it a region that already has a live token is refused, because two
	// standing credentials for one node is a state nothing can reason about.
	Reissue bool `json:"reissue,omitempty"`

	// --- onboard phase only ---

	// The appliance presenting itself. Piri's DID belongs to a key generated on
	// the node, and the proof is signed by it, so neither is derivable here.
	// Ingot's is derived from its region and the stage's filonecontent.com
	// suffix, following the Forge service identity RFC.
	PiriDID string `json:"piri_did,omitempty"`
	PiriURL string `json:"piri_url,omitempty"`
	// IngotDID is accepted only to be refused, so a caller working from the old
	// contract is told the input is gone rather than having it ignored.
	IngotDID string `json:"ingot_did,omitempty"`
	// PiriProof is the delegation the appliance signed for sprue, in whatever
	// container ucantool wrote, given as text.
	PiriProof string `json:"piri_proof,omitempty"`
	// PiriProofB64 is the same delegation base64-encoded, which is how
	// scripts/onboard-appliance.sh sends it. A bare DAG-CBOR container is binary
	// and carries NUL bytes, and neither a shell variable nor a JSON string can
	// hold one, so the script encodes every proof file rather than guessing
	// which form it holds. The two fields are mutually exclusive.
	PiriProofB64 string `json:"piri_proof_b64,omitempty"`
	// Weights default to smelt's 100/100.
	Weight            int `json:"weight,omitempty"`
	ReplicationWeight int `json:"replication_weight,omitempty"`

	// --- fund, appliance-token and onboard phases ---

	// Confirm must be true before a phase signs or mints anything. Without it
	// the phase reports its plan and stops, so no invocation moves money or
	// issues a credential by accident.
	Confirm bool `json:"confirm,omitempty"`

	// --- fund phase only ---

	// Amounts are decimal USDFC strings exactly as the operator typed them, so
	// the number shown in the confirmation prompt is the number that is signed.
	// Empty means the default.
	Deposit         string `json:"deposit,omitempty"`
	LockupAllowance string `json:"lockup_allowance,omitempty"`
	RateAllowance   string `json:"rate_allowance,omitempty"`
	MaxLockupPeriod uint64 `json:"max_lockup_period,omitempty"`
	ForceDeposit    bool   `json:"force_deposit,omitempty"`
}

// Response carries public material back into Terraform state. Every field here
// is safe to read by anyone with state access, which is the point.
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

	// ApplianceKeys lists the transit keys this stage now holds, one per live
	// region. Retired lists the regions this invocation destroyed keys for.
	ApplianceKeys     []string `json:"appliance_keys,omitempty"`
	RetiredAppliances []string `json:"retired_appliances,omitempty"`

	// DryRun is true when a phase reported a plan without acting.
	DryRun     bool         `json:"dry_run,omitempty"`
	FundPlan   *fund.Plan   `json:"fund_plan,omitempty"`
	FundResult *fund.Result `json:"fund_result,omitempty"`

	// TokenPlan and TokenResult belong to the appliance-token phase.
	//
	// TokenResult is the one field in this struct that is not safe to put in
	// Terraform state: it carries a wrapping token that exchanges for a live
	// credential. That is why no aws_lambda_invocation calls that phase.
	TokenPlan   *TokenPlan   `json:"token_plan,omitempty"`
	TokenResult *TokenResult `json:"token_result,omitempty"`

	// OnboardPlan and OnboardResult belong to the onboard phase. Both are
	// public: the result's proof is a delegation, which is useless without the
	// audience's own key.
	OnboardPlan   *onboard.Plan   `json:"onboard_plan,omitempty"`
	OnboardResult *onboard.Result `json:"onboard_result,omitempty"`

	// RetirePlan and RetireResult belong to the retire phase, and carry only
	// DIDs, row counts and parameter names.
	RetirePlan   *RetirePlan   `json:"retire_plan,omitempty"`
	RetireResult *RetireResult `json:"retire_result,omitempty"`
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
		return deps.vault(ctx, req)
	case "fund":
		return deps.fund(ctx, req)
	case "appliance-token":
		return deps.applianceToken(ctx, req)
	case "onboard":
		return deps.onboardPhase(ctx, req)
	case "retire":
		return deps.retirePhase(ctx, req)
	default:
		return nil, fmt.Errorf(
			"unknown phase %q; want \"seed\", \"vault\", \"fund\", \"appliance-token\", \"onboard\" or \"retire\"", req.Phase)
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
