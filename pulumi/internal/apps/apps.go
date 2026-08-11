// Package apps builds the six ECS services.
//
// Everything here is derived from the platform stack's outputs plus the SSM
// parameters the provision Lambda wrote. No secret value appears in this
// configuration; only parameter ARNs, which ECS resolves at task start.
//
// Service-specific quirks worth knowing before reading further:
//
//	hilt, swarf    default to binding 127.0.0.1, so they need an explicit host
//	hilt, swarf    accept the identity key only as a file path
//	delegator      needs its UCAN proofs as files; the inline form panics
//	delegator      uses DynamoDB and no Postgres at all
//	plc            has no public hostname, matching smelt
//	health paths   /health, /healthcheck and /_health all appear below
package apps

import (
	"fmt"
	"strconv"
	"strings"

	"github.com/pulumi/pulumi-aws/sdk/v7/go/aws"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"

	"github.com/fil-forge/infra-central/pulumi/internal/chain"
	"github.com/fil-forge/infra-central/pulumi/internal/ecsservice"
	"github.com/fil-forge/infra-central/pulumi/internal/iamdoc"
)

// Digests pins one image per service. A digest names one artifact and cannot move
// underneath a running service, so what a stage runs is a committed fact rather
// than whatever the tag pointed at when the task last started.
type Digests struct {
	Sprue          string `json:"sprue"`
	Hilt           string `json:"hilt"`
	Swarf          string `json:"swarf"`
	Delegator      string `json:"delegator"`
	SigningService string `json:"signing_service"`
	PLC            string `json:"plc"`
}

// Validate rejects anything that is not a digest. A tag here would produce an
// image reference that pulls at task start and fails there instead.
func (d Digests) Validate() error {
	for _, pinned := range []struct{ service, digest string }{
		{"sprue", d.Sprue},
		{"hilt", d.Hilt},
		{"swarf", d.Swarf},
		{"delegator", d.Delegator},
		{"signing_service", d.SigningService},
		{"plc", d.PLC},
	} {
		if !strings.HasPrefix(pinned.digest, "sha256:") {
			return fmt.Errorf("image digest for %s is %q; every service must be pinned by digest, in the form sha256:<hex>", pinned.service, pinned.digest)
		}
	}

	return nil
}

// Size is one service's Fargate CPU and memory.
type Size struct {
	CPU    int `json:"cpu"`
	Memory int `json:"memory"`
}

// DefaultSizes is the per-service allocation a stage gets unless it says
// otherwise.
var DefaultSizes = map[string]Size{
	"sprue":           {CPU: 512, Memory: 1024},
	"hilt":            {CPU: 512, Memory: 1024},
	"swarf":           {CPU: 256, Memory: 512},
	"delegator":       {CPU: 256, Memory: 512},
	"signing-service": {CPU: 256, Memory: 512},
	"plc":             {CPU: 256, Memory: 512},
}

// Args is what the apps stack passes in. Everything but Stage, the digests and
// the two policy switches comes from the platform stack's outputs.
type Args struct {
	// Stage names the resources. It is the stack's own name, which is also the
	// platform stack's, so the two cannot disagree about which stage this is.
	Stage string

	HostnameSuffix pulumi.StringInput

	ClusterArn      pulumi.StringInput
	VpcID           pulumi.StringInput
	SubnetIDs       pulumi.StringArrayInput
	SecurityGroupID pulumi.StringInput

	ListenerArn   pulumi.StringInput
	Route53ZoneID pulumi.StringInput
	AlbDNSName    pulumi.StringInput
	AlbZoneID     pulumi.StringInput

	NamespaceID   pulumi.StringInput
	NamespaceName pulumi.StringInput

	BucketNames pulumi.StringMap
	BucketArns  pulumi.StringArrayInput

	AllowListTableName    pulumi.StringInput
	ProviderInfoTableName pulumi.StringInput
	DynamoDBTableArns     pulumi.StringArrayInput

	OpenBaoInternalAddress pulumi.StringInput

	// IndexerDID and EtrackerDID name services that are not deployed yet. The
	// delegator validates proofs signed by these DIDs at startup, so the names
	// have to be settled even though nothing answers at them.
	IndexerDID  pulumi.StringInput
	EtrackerDID pulumi.StringInput

	ImageDigests Digests

	// Chain is read from the platform stack so it has one home per stage. Only
	// the delegator and signing service use the RPC, and both make plain
	// request/response calls, so https works.
	Chain chain.Inputs

	// AllowProvisionWithoutPaymentPlan lets sprue provision storage with no
	// payment plan attached. True in smelt's staging.
	AllowProvisionWithoutPaymentPlan bool

	// LogLevel defaults to info.
	LogLevel string

	// Sizes overrides DefaultSizes per service.
	Sizes map[string]Size
}

// Apps is the deployed set of services.
type Apps struct {
	pulumi.ResourceState

	// ServiceURLs is the public URL per service. plc is absent because it has no
	// public hostname.
	ServiceURLs pulumi.StringMap

	// ServiceDIDs is the did:web each service was given. sprue, hilt, swarf and
	// the delegator publish a document at /.well-known/did.json;
	// piri-signing-service does not, so its DID resolves nowhere. Nothing
	// addresses it by DID today.
	ServiceDIDs pulumi.StringMap

	PlcInternalURL pulumi.StringOutput

	LogGroups pulumi.StringMap
}

// naming builds the hostnames, URLs and DIDs every service shares a shape for.
//
// Services address each other by did:web, which resolves over public HTTPS. A
// task in a private subnet therefore reaches the public ALB back out through the
// NAT gateway.
type naming struct {
	suffix pulumi.StringOutput
}

func (n naming) host(service string) pulumi.StringOutput {
	return n.suffix.ApplyT(func(suffix string) string {
		return service + "." + suffix
	}).(pulumi.StringOutput)
}

func (n naming) url(service string) pulumi.StringOutput {
	return n.host(service).ApplyT(func(host string) string { return "https://" + host }).(pulumi.StringOutput)
}

func (n naming) did(service string) pulumi.StringOutput {
	return n.host(service).ApplyT(func(host string) string { return "did:web:" + host }).(pulumi.StringOutput)
}

// New builds all six services.
func New(ctx *pulumi.Context, name string, args *Args, opts ...pulumi.ResourceOption) (*Apps, error) {
	if args.Stage == "" {
		return nil, fmt.Errorf("apps: stage is required")
	}
	if err := args.ImageDigests.Validate(); err != nil {
		return nil, fmt.Errorf("apps %s: %w", args.Stage, err)
	}
	if args.LogLevel == "" {
		args.LogLevel = "info"
	}

	component := &Apps{
		ServiceURLs: pulumi.StringMap{},
		ServiceDIDs: pulumi.StringMap{},
		LogGroups:   pulumi.StringMap{},
	}
	if err := ctx.RegisterComponentResource("forge:index:Apps", name, component, opts...); err != nil {
		return nil, err
	}

	child := []pulumi.ResourceOption{pulumi.Parent(component)}
	invoke := pulumi.InvokeOption(pulumi.Parent(component))

	identity, err := aws.GetCallerIdentity(ctx, nil, invoke)
	if err != nil {
		return nil, fmt.Errorf("apps: look up the caller's account: %w", err)
	}

	region, err := aws.GetRegion(ctx, nil, invoke)
	if err != nil {
		return nil, fmt.Errorf("apps: look up the provider's region: %w", err)
	}

	build := &builder{
		args:      args,
		names:     naming{suffix: args.HostnameSuffix.ToStringOutput()},
		region:    region.Region,
		accountID: identity.AccountId,
		ssm:       fmt.Sprintf("arn:aws:ssm:%s:%s:parameter/forge-central/%s", region.Region, identity.AccountId, args.Stage),
		child:     child,

		// Where the entrypoint wrapper drops file-borne secrets.
		keys: ecsservice.SecretDir,
	}

	build.plcDirectory = args.NamespaceName.ToStringOutput().ApplyT(func(namespace string) string {
		return fmt.Sprintf("http://plc.%s:3000", namespace)
	}).(pulumi.StringOutput)

	services := []struct {
		name string
		make func(*pulumi.Context) (*ecsservice.Service, error)
	}{
		{"sprue", build.sprue},
		{"hilt", build.hilt},
		{"swarf", build.swarf},
		{"delegator", build.delegator},
		{"signing-service", build.signingService},
		{"plc", build.plc},
	}

	for _, service := range services {
		built, err := service.make(ctx)
		if err != nil {
			return nil, fmt.Errorf("apps: %s: %w", service.name, err)
		}

		component.LogGroups[service.name] = built.LogGroupName
		component.ServiceDIDs[service.name] = build.names.did(service.name)

		if built.Public {
			component.ServiceURLs[service.name] = built.PublicURL
		}
	}

	// plc has no public hostname, so it has no DID anyone resolves either. It is
	// listed among the log groups above and nowhere else.
	delete(component.ServiceDIDs, "plc")

	component.PlcInternalURL = build.plcDirectory

	if err := ctx.RegisterResourceOutputs(component, pulumi.Map{
		"plcInternalUrl": component.PlcInternalURL,
	}); err != nil {
		return nil, err
	}

	return component, nil
}

// builder carries what every service needs, so each method below reads as the
// service's own configuration and nothing else.
type builder struct {
	args         *Args
	names        naming
	region       string
	accountID    string
	ssm          string
	keys         string
	plcDirectory pulumi.StringOutput
	child        []pulumi.ResourceOption
}

// size returns the Fargate allocation for a service, preferring the stage's
// override.
func (b *builder) size(service string) Size {
	if override, ok := b.args.Sizes[service]; ok {
		return override
	}

	return DefaultSizes[service]
}

// base is the part of every service's configuration that does not vary.
func (b *builder) base(service string, port int) ecsservice.Args {
	allocation := b.size(service)

	return ecsservice.Args{
		Stage:     b.args.Stage,
		Service:   service,
		Region:    b.region,
		AccountID: b.accountID,

		ContainerPort: port,

		ClusterArn:      b.args.ClusterArn,
		VpcID:           b.args.VpcID,
		SubnetIDs:       b.args.SubnetIDs,
		SecurityGroupID: b.args.SecurityGroupID,

		CPU:    allocation.CPU,
		Memory: allocation.Memory,
	}
}

// public fills in the routing a service with a public identity needs.
func (b *builder) public(args *ecsservice.Args, service string, priority int) {
	args.Hostname = b.names.host(service)
	args.ListenerArn = b.args.ListenerArn
	args.ListenerPriority = priority
	args.Route53ZoneID = b.args.Route53ZoneID
	args.AlbDNSName = b.args.AlbDNSName
	args.AlbZoneID = b.args.AlbZoneID
}

// --- sprue ---------------------------------------------------------------

func (b *builder) sprue(ctx *pulumi.Context) (*ecsservice.Service, error) {
	args := b.base("sprue", 8080)

	args.Image = pulumi.String("ghcr.io/fil-forge/sprue@" + b.args.ImageDigests.Sprue)

	args.Environment = pulumi.StringMap{
		"SPRUE_SERVER_HOST":          pulumi.String("0.0.0.0"),
		"SPRUE_SERVER_PORT":          pulumi.String("8080"),
		"SPRUE_SERVER_PUBLIC_URL":    b.names.url("sprue"),
		"SPRUE_IDENTITY_KEY_FILE":    pulumi.String(b.keys + "/identity.pem"),
		"SPRUE_IDENTITY_SERVICE_DID": b.names.did("sprue"),

		"SPRUE_DEPLOYMENT_ENVIRONMENT":                          pulumi.String(b.args.Stage),
		"SPRUE_DEPLOYMENT_ALLOW_PROVISION_WITHOUT_PAYMENT_PLAN": pulumi.String(strconv.FormatBool(b.args.AllowProvisionWithoutPaymentPlan)),
		"SPRUE_DEPLOYMENT_PLC_DIRECTORY":                        b.plcDirectory,

		// Empty disables the indexer, as in smelt's staging config.
		"SPRUE_INDEXER_ENDPOINT": pulumi.String(""),
		"SPRUE_INDEXER_DID":      pulumi.String(""),

		"SPRUE_STORAGE_TYPE": pulumi.String("postgres"),

		// An empty endpoint means real S3: the AWS default credential chain
		// applies, so the bucket is reached through the task role and there are
		// no static keys anywhere. This is what replaces smelt's MinIO root user
		// and password.
		//
		// It has to be set rather than left out. sprue defaults the endpoint to
		// http://minio:9000, and a task inheriting that default resolves bucket
		// names against a host that does not exist in the VPC.
		"SPRUE_STORAGE_S3_ENDPOINT":             pulumi.String(""),
		"SPRUE_STORAGE_S3_REGION":               pulumi.String(b.region),
		"SPRUE_STORAGE_S3_AGENT_MESSAGE_BUCKET": b.args.BucketNames["agent-message"],
		"SPRUE_STORAGE_S3_DELEGATION_BUCKET":    b.args.BucketNames["delegation"],
		"SPRUE_STORAGE_S3_UPLOAD_SHARDS_BUCKET": b.args.BucketNames["upload-shards"],

		"SPRUE_MAILER_TYPE": pulumi.String("nop"),
		"SPRUE_LOG_LEVEL":   pulumi.String(b.args.LogLevel),
	}

	args.Secrets = pulumi.StringMap{
		"SPRUE_STORAGE_POSTGRES_DSN": pulumi.String(b.ssm + "/sprue/postgres-dsn"),
		"SPRUE_IDENTITY_KEY_PEM":     pulumi.String(b.ssm + "/sprue/identity"),
	}

	args.SecretFiles = map[string]string{"SPRUE_IDENTITY_KEY_PEM": "identity.pem"}
	args.ShellCommand = pulumi.String("sprue serve")

	args.HealthCheckCommand = "curl -sf http://127.0.0.1:8080/health"
	args.HealthCheckPath = "/health"

	b.public(&args, "sprue", 110)

	// Object access, scoped to sprue's own three buckets.
	args.TaskPolicies = map[string]pulumi.StringInput{
		"service-permissions": b.args.BucketArns.ToStringArrayOutput().ApplyT(func(arns []string) (string, error) {
			resources := make([]string, 0, len(arns)*2)
			resources = append(resources, arns...)
			for _, arn := range arns {
				resources = append(resources, arn+"/*")
			}

			return iamdoc.New(iamdoc.Statement{
				Sid:       "ObjectAccess",
				Actions:   []string{"s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"},
				Resources: resources,
			}).JSON()
		}).(pulumi.StringOutput),
	}

	return ecsservice.New(ctx, "sprue", &args, b.child...)
}

// --- hilt ----------------------------------------------------------------

func (b *builder) hilt(ctx *pulumi.Context) (*ecsservice.Service, error) {
	args := b.base("hilt", 8080)

	args.Image = pulumi.String("ghcr.io/fil-forge/hilt@" + b.args.ImageDigests.Hilt)

	args.Environment = pulumi.StringMap{
		// hilt binds 127.0.0.1 by default, which no health check can reach.
		"HILT_SERVER_HOST": pulumi.String("0.0.0.0"),
		"HILT_SERVER_PORT": pulumi.String("8080"),

		"HILT_IDENTITY_KEY_FILE":   pulumi.String(b.keys + "/identity.pem"),
		"HILT_IDENTITY_SERVICE_ID": b.names.did("hilt"),

		"HILT_STORAGE_TYPE": pulumi.String("postgres"),

		"HILT_VAULT_TYPE":                  pulumi.String("hashicorp"),
		"HILT_VAULT_HASHICORP_ADDRESS":     b.args.OpenBaoInternalAddress,
		"HILT_VAULT_HASHICORP_AUTH_METHOD": pulumi.String("approle"),
		// Mounting KV v2 at forge-central/hilt puts every tenant secret under
		// that prefix without changing hilt, whose path builder is already
		// mount-relative.
		"HILT_VAULT_HASHICORP_MOUNT": pulumi.String("forge-central/hilt"),

		"HILT_PLC_DIRECTORY": b.plcDirectory,

		"HILT_UPLOAD_SERVICE_ID":  b.names.did("sprue"),
		"HILT_UPLOAD_SERVICE_URL": b.names.url("sprue"),
		"HILT_UPLOAD_PRODUCT_ID":  b.names.did("hilt"),
		"HILT_UPLOAD_PROOFS":      pulumi.String(b.keys + "/upload-proof.txt"),

		"HILT_LOG_LEVEL": pulumi.String(b.args.LogLevel),
	}

	args.Secrets = pulumi.StringMap{
		"HILT_STORAGE_POSTGRES_DSN":              pulumi.String(b.ssm + "/hilt/postgres-dsn"),
		"HILT_AUTH_PARTNER_KEY":                  pulumi.String(b.ssm + "/hilt/partner-key"),
		"HILT_VAULT_HASHICORP_APPROLE_ROLE_ID":   pulumi.String(b.ssm + "/hilt/vault-role-id"),
		"HILT_VAULT_HASHICORP_APPROLE_SECRET_ID": pulumi.String(b.ssm + "/hilt/vault-secret-id"),
		"HILT_IDENTITY_KEY_PEM":                  pulumi.String(b.ssm + "/hilt/identity"),
		"HILT_UPLOAD_PROOF":                      pulumi.String(b.ssm + "/hilt/upload-proof"),
	}

	args.SecretFiles = map[string]string{
		"HILT_IDENTITY_KEY_PEM": "identity.pem",
		"HILT_UPLOAD_PROOF":     "upload-proof.txt",
	}
	args.ShellCommand = pulumi.String("hilt serve")

	args.HealthCheckCommand = "curl -sf http://127.0.0.1:8080/health"
	args.HealthCheckPath = "/health"

	b.public(&args, "hilt", 120)

	return ecsservice.New(ctx, "hilt", &args, b.child...)
}

// --- swarf ---------------------------------------------------------------

func (b *builder) swarf(ctx *pulumi.Context) (*ecsservice.Service, error) {
	args := b.base("swarf", 8080)

	args.Image = pulumi.String("ghcr.io/fil-forge/swarf@" + b.args.ImageDigests.Swarf)

	args.Environment = pulumi.StringMap{
		"SWARF_SERVER_HOST": pulumi.String("0.0.0.0"),
		"SWARF_SERVER_PORT": pulumi.String("8080"),

		"SWARF_IDENTITY_KEY_FILE":   pulumi.String(b.keys + "/identity.pem"),
		"SWARF_IDENTITY_SERVICE_ID": b.names.did("swarf"),

		"SWARF_STORAGE_TYPE":  pulumi.String("postgres"),
		"SWARF_PLC_DIRECTORY": b.plcDirectory,
		"SWARF_LOG_LEVEL":     pulumi.String(b.args.LogLevel),
	}

	args.Secrets = pulumi.StringMap{
		"SWARF_STORAGE_POSTGRES_DSN": pulumi.String(b.ssm + "/swarf/postgres-dsn"),
		"SWARF_IDENTITY_KEY_PEM":     pulumi.String(b.ssm + "/swarf/identity"),
	}

	args.SecretFiles = map[string]string{"SWARF_IDENTITY_KEY_PEM": "identity.pem"}
	args.ShellCommand = pulumi.String("swarf serve")

	args.HealthCheckCommand = "curl -sf http://127.0.0.1:8080/health"
	args.HealthCheckPath = "/health"

	b.public(&args, "swarf", 130)

	return ecsservice.New(ctx, "swarf", &args, b.child...)
}

// --- delegator -----------------------------------------------------------

func (b *builder) delegator(ctx *pulumi.Context) (*ecsservice.Service, error) {
	args := b.base("delegator", 8080)

	args.Image = pulumi.String("ghcr.io/fil-forge/delegator@" + b.args.ImageDigests.Delegator)

	args.Environment = pulumi.StringMap{
		"REGISTRAR_SERVER_HOST": pulumi.String("0.0.0.0"),
		"REGISTRAR_SERVER_PORT": pulumi.String("8080"),

		// DynamoDB, reached through the task role. The delegator uses no
		// Postgres.
		"REGISTRAR_STORE_REGION":                  pulumi.String(b.region),
		"REGISTRAR_STORE_ALLOWLIST_TABLE_NAME":    b.args.AllowListTableName,
		"REGISTRAR_STORE_PROVIDERINFO_TABLE_NAME": b.args.ProviderInfoTableName,

		"REGISTRAR_DELEGATOR_DID": b.names.did("delegator"),

		// Both proofs must be files: the inline variants panic in current code.
		"REGISTRAR_DELEGATOR_INDEXING_SERVICE_PROOF_FILE":        pulumi.String(b.keys + "/indexing-service-proof.txt"),
		"REGISTRAR_DELEGATOR_EGRESS_TRACKING_SERVICE_PROOF_FILE": pulumi.String(b.keys + "/egress-tracking-proof.txt"),
		"REGISTRAR_DELEGATOR_INDEXING_SERVICE_WEB_DID":           b.args.IndexerDID,
		"REGISTRAR_DELEGATOR_EGRESS_TRACKING_SERVICE_DID":        b.args.EtrackerDID,
		"REGISTRAR_DELEGATOR_UPLOAD_SERVICE_DID":                 b.names.did("sprue"),

		"REGISTRAR_CONTRACT_CHAIN_CLIENT_ENDPOINT":     b.args.Chain.RPCURL,
		"REGISTRAR_CONTRACT_PAYMENTS_CONTRACT_ADDRESS": b.args.Chain.FilecoinPay,
		"REGISTRAR_CONTRACT_SERVICE_CONTRACT_ADDRESS":  b.args.Chain.FWSS,
		"REGISTRAR_CONTRACT_REGISTRY_CONTRACT_ADDRESS": b.args.Chain.ServiceProviderRegistry,
		"REGISTRAR_CONTRACT_TRANSACTOR_CHAIN_ID":       b.args.Chain.ChainID,
	}

	args.Secrets = pulumi.StringMap{
		"REGISTRAR_DELEGATOR_KEY":           pulumi.String(b.ssm + "/delegator/identity-multibase"),
		"REGISTRAR_CONTRACT_TRANSACTOR_KEY": pulumi.String(b.ssm + "/delegator/transactor-key"),
		"DELEGATOR_INDEXING_PROOF":          pulumi.String(b.ssm + "/delegator/indexing-service-proof"),
		"DELEGATOR_EGRESS_PROOF":            pulumi.String(b.ssm + "/delegator/egress-tracking-proof"),
	}

	// Both proofs are bare DAG-CBOR, so they are stored base64-encoded: their raw
	// bytes contain NULs, which an environment variable cannot carry.
	args.SecretFilesBase64 = map[string]string{
		"DELEGATOR_INDEXING_PROOF": "indexing-service-proof.txt",
		"DELEGATOR_EGRESS_PROOF":   "egress-tracking-proof.txt",
	}
	args.ShellCommand = pulumi.String("registrar serve")

	// Alpine base: wget rather than curl. Note /healthcheck, not /health.
	args.HealthCheckCommand = "wget -q --spider http://127.0.0.1:8080/healthcheck"
	args.HealthCheckPath = "/healthcheck"

	b.public(&args, "delegator", 140)

	args.TaskPolicies = map[string]pulumi.StringInput{
		"service-permissions": b.args.DynamoDBTableArns.ToStringArrayOutput().ApplyT(func(arns []string) (string, error) {
			return iamdoc.New(iamdoc.Statement{
				Sid: "RegistryTables",
				Actions: []string{
					// The store describes both tables at startup and refuses to
					// run if it cannot: with no endpoint override it takes a
					// missing table as a sign it is pointed at the wrong account,
					// rather than creating one.
					"dynamodb:DescribeTable",

					"dynamodb:GetItem",
					"dynamodb:PutItem",
					"dynamodb:UpdateItem",
					"dynamodb:DeleteItem",
					"dynamodb:Query",
					"dynamodb:Scan",
				},
				Resources: arns,
			}).JSON()
		}).(pulumi.StringOutput),
	}

	return ecsservice.New(ctx, "delegator", &args, b.child...)
}

// --- signing service -----------------------------------------------------

func (b *builder) signingService(ctx *pulumi.Context) (*ecsservice.Service, error) {
	args := b.base("signing-service", 7446)

	args.Image = pulumi.String("ghcr.io/fil-forge/piri-signing-service@" + b.args.ImageDigests.SigningService)

	args.Environment = pulumi.StringMap{
		"SIGNING_SERVICE_HOST":                     pulumi.String("0.0.0.0"),
		"SIGNING_SERVICE_PORT":                     pulumi.String("7446"),
		"SIGNING_SERVICE_RPC_URL":                  b.args.Chain.RPCURL,
		"SIGNING_SERVICE_SERVICE_CONTRACT_ADDRESS": b.args.Chain.FWSS,
		"SIGNING_SERVICE_SERVICE_DID":              b.names.did("signing-service"),
	}

	// This service takes both keys inline, so it needs no file wrapper at all.
	args.Secrets = pulumi.StringMap{
		"SIGNING_SERVICE_SERVICE_KEY": pulumi.String(b.ssm + "/signing-service/identity-multibase"),
		"SIGNING_SERVICE_SIGNING_KEY": pulumi.String(b.ssm + "/signing-service/payer-key"),
	}

	args.HealthCheckCommand = "wget -q --spider http://127.0.0.1:7446/healthcheck"
	args.HealthCheckPath = "/healthcheck"

	b.public(&args, "signing-service", 150)

	return ecsservice.New(ctx, "signing-service", &args, b.child...)
}

// --- plc directory -------------------------------------------------------

func (b *builder) plc(ctx *pulumi.Context) (*ecsservice.Service, error) {
	args := b.base("plc", 3000)

	args.Image = pulumi.String("ghcr.io/fil-forge/did-method-plc@" + b.args.ImageDigests.PLC)

	args.Environment = pulumi.StringMap{
		"ENABLE_MIGRATIONS": pulumi.String("true"),
		"PORT":              pulumi.String("3000"),
	}

	args.Secrets = pulumi.StringMap{
		"DB_CREDS_JSON":         pulumi.String(b.ssm + "/plc/db-creds-json"),
		"DB_MIGRATE_CREDS_JSON": pulumi.String(b.ssm + "/plc/db-creds-json"),
	}

	args.HealthCheckCommand = "wget -q --spider http://127.0.0.1:3000/_health"
	args.HealthCheckPath = "/_health"

	// No public hostname, matching smelt, which gives plc no route and no DNS
	// record. Only sprue and hilt call it, both from inside the VPC. Hostname is
	// left nil, which is what suppresses the target group, listener rule and
	// public record.
	args.RegisterInternal = true
	args.NamespaceID = b.args.NamespaceID
	args.NamespaceName = b.args.NamespaceName

	return ecsservice.New(ctx, "plc", &args, b.child...)
}
