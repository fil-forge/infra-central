// Package platform assembles everything in a stage that changes rarely: network,
// database, storage, ingress, OpenBao, and the Lambda that mints the stage's
// secrets.
//
// This composite exists so each stage's program stays a short list of what
// differs. Duplicating the wiring per stage would be the fastest route to two
// stages that quietly stopped resembling each other.
//
// The bootstrap order below is the load-bearing part:
//
//	database  ->  seed  ->  openbao  ->  vault
//
// seed creates OpenBao's own database, so it must finish before OpenBao starts.
// vault configures a running OpenBao, so it cannot run until the service is up.
package platform

import (
	"encoding/json"
	"fmt"

	"github.com/pulumi/pulumi-aws/sdk/v7/go/aws"
	"github.com/pulumi/pulumi-aws/sdk/v7/go/aws/ecs"
	"github.com/pulumi/pulumi-aws/sdk/v7/go/aws/lambda"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"

	"github.com/fil-forge/infra-central/pulumi/internal/chain"
	"github.com/fil-forge/infra-central/pulumi/internal/platform/database"
	"github.com/fil-forge/infra-central/pulumi/internal/platform/ingress"
	"github.com/fil-forge/infra-central/pulumi/internal/platform/kms"
	"github.com/fil-forge/infra-central/pulumi/internal/platform/network"
	"github.com/fil-forge/infra-central/pulumi/internal/platform/openbao"
	"github.com/fil-forge/infra-central/pulumi/internal/platform/provision"
	"github.com/fil-forge/infra-central/pulumi/internal/platform/storage"
)

// Args is what a stage's program has to say. Everything not set here takes the
// default the module documents, so a stage names only what it does differently.
type Args struct {
	Stage string

	// ZoneName is an existing Route53 hosted zone, e.g. fil.one.
	ZoneName string

	// HostnameSuffix is the suffix every service hostname shares, e.g.
	// dev.fil.one.
	HostnameSuffix string

	// VpcCIDR defaults to 10.20.0.0/16.
	VpcCIDR string

	// ProvisionImageRepositoryURL is the ECR repository URL from the bootstrap
	// stack for this stage's region, and ProvisionImageDigest the manifest digest
	// from `make publish`.
	ProvisionImageRepositoryURL string
	ProvisionImageDigest        string

	Chain chain.Config

	DBInstanceClass       string
	DBAllocatedStorage    int
	DBBackupRetentionDays int

	// DBMultiAZ defaults to true. Nil rather than a bare bool so the safe answer
	// is what an unset field gives.
	DBMultiAZ *bool

	// ProtectStatefulResources turns on deletion protection on RDS and the ALB,
	// and a final snapshot on destroy. Losing the database means losing OpenBao's
	// storage and with it every appliance's ability to unseal. Defaults to true.
	ProtectStatefulResources *bool

	// OpenBaoImage defaults to openbao/openbao:2.6.0.
	OpenBaoImage string

	// OpenBaoMaxParallel is the number of Postgres connections OpenBao may open.
	// Budget against the instance's max_connections alongside the application
	// services. Defaults to 16.
	OpenBaoMaxParallel int

	ContainerInsights bool

	// SeedTrigger and VaultTrigger force their phase to run again when changed,
	// for example after rotating hilt's AppRole. Empty means "1".
	SeedTrigger  string
	VaultTrigger string
}

// Platform is a stage's long-lived infrastructure. The first block of fields is
// what the apps stack reads; the rest is public material the provision Lambda
// returned.
type Platform struct {
	pulumi.ResourceState

	Stage          string
	HostnameSuffix string

	ClusterArn             pulumi.StringOutput
	VpcID                  pulumi.StringOutput
	PrivateSubnetIDs       pulumi.StringArray
	ServiceSecurityGroupID pulumi.StringOutput
	NamespaceID            pulumi.StringOutput
	NamespaceName          pulumi.StringOutput
	ListenerArn            pulumi.StringOutput
	AlbDNSName             pulumi.StringOutput
	AlbZoneID              pulumi.StringOutput
	Route53ZoneID          pulumi.StringOutput

	BucketNames           pulumi.StringMap
	BucketArns            pulumi.StringArray
	AllowListTableName    pulumi.StringOutput
	ProviderInfoTableName pulumi.StringOutput
	DynamoDBTableArns     pulumi.StringArray

	OpenBaoInternalAddress pulumi.StringOutput
	OpenBaoPublicURL       pulumi.StringOutput

	Chain chain.Config

	// ServiceDIDs maps a service name to its did:key. Stable across task
	// restarts, which is the point of injecting identity keys rather than letting
	// services generate them.
	ServiceDIDs pulumi.StringMapOutput

	// WalletAddresses maps a wallet name to its EIP-55 address. These are the
	// accounts to fund with tFIL and USDFC.
	WalletAddresses pulumi.StringMapOutput

	Databases pulumi.StringArrayOutput

	// CreatedParameters lists parameters minted by the most recent run. Empty on
	// a steady-state run, which is how you confirm nothing was regenerated.
	CreatedParameters pulumi.StringArrayOutput

	OpenBaoInitialised pulumi.BoolOutput
}

// New builds the stage.
func New(ctx *pulumi.Context, name string, args *Args, opts ...pulumi.ResourceOption) (*Platform, error) {
	if args.Stage == "" || args.ZoneName == "" || args.HostnameSuffix == "" {
		return nil, fmt.Errorf("platform: stage, zone name and hostname suffix are all required")
	}
	if err := args.Chain.Validate(); err != nil {
		return nil, fmt.Errorf("platform %s: %w", args.Stage, err)
	}

	if args.SeedTrigger == "" {
		args.SeedTrigger = "1"
	}
	if args.VaultTrigger == "" {
		args.VaultTrigger = "1"
	}

	protect := boolOr(args.ProtectStatefulResources, true)

	component := &Platform{Stage: args.Stage, HostnameSuffix: args.HostnameSuffix, Chain: args.Chain}
	if err := ctx.RegisterComponentResource("forge:index:Platform", name, component, opts...); err != nil {
		return nil, err
	}

	child := []pulumi.ResourceOption{pulumi.Parent(component)}
	invoke := pulumi.InvokeOption(pulumi.Parent(component))

	identity, err := aws.GetCallerIdentity(ctx, nil, invoke)
	if err != nil {
		return nil, fmt.Errorf("platform: look up the caller's account: %w", err)
	}

	region, err := aws.GetRegion(ctx, nil, invoke)
	if err != nil {
		return nil, fmt.Errorf("platform: look up the provider's region: %w", err)
	}

	net, err := network.New(ctx, name+"-network", &network.Args{
		Stage:   args.Stage,
		VpcCIDR: args.VpcCIDR,
	}, child...)
	if err != nil {
		return nil, err
	}

	seal, err := kms.New(ctx, name+"-kms", &kms.Args{
		Stage:                args.Stage,
		DeletionWindowInDays: deletionWindow(protect),
	}, child...)
	if err != nil {
		return nil, err
	}

	db, err := database.New(ctx, name+"-database", &database.Args{
		Stage:           args.Stage,
		SubnetIDs:       net.PrivateSubnetIDs,
		SecurityGroupID: net.DatabaseSecurityGroupID,

		InstanceClass:       args.DBInstanceClass,
		AllocatedStorage:    args.DBAllocatedStorage,
		MultiAZ:             boolOr(args.DBMultiAZ, true),
		BackupRetentionDays: args.DBBackupRetentionDays,
		DeletionProtection:  protect,
		SkipFinalSnapshot:   !protect,
	}, child...)
	if err != nil {
		return nil, err
	}

	store, err := storage.New(ctx, name+"-storage", &storage.Args{
		Stage:               args.Stage,
		AccountID:           identity.AccountId,
		ForceDestroy:        !protect,
		PointInTimeRecovery: protect,
	}, child...)
	if err != nil {
		return nil, err
	}

	entry, err := ingress.New(ctx, name+"-ingress", &ingress.Args{
		Stage:              args.Stage,
		ZoneName:           args.ZoneName,
		HostnameSuffix:     args.HostnameSuffix,
		PublicSubnetIDs:    net.PublicSubnetIDs,
		SecurityGroupID:    net.AlbSecurityGroupID,
		DeletionProtection: protect,
	}, child...)
	if err != nil {
		return nil, err
	}

	cluster, err := ecs.NewCluster(ctx, name+"-cluster", &ecs.ClusterArgs{
		Name: pulumi.String("fc-" + args.Stage),
		Settings: ecs.ClusterSettingArray{
			&ecs.ClusterSettingArgs{
				Name:  pulumi.String("containerInsights"),
				Value: pulumi.String(insights(args.ContainerInsights)),
			},
		},
	}, child...)
	if err != nil {
		return nil, err
	}

	// The internal address the Lambda's vault phase uses. Stated from the
	// namespace rather than read back from the OpenBao module, because the
	// function has to be created before the service that answers there.
	openBaoAddress := net.NamespaceName.ApplyT(func(namespace string) string {
		return fmt.Sprintf("http://openbao.%s:8200", namespace)
	}).(pulumi.StringOutput)

	minter, err := provision.New(ctx, name+"-provision", &provision.Args{
		Stage:     args.Stage,
		Region:    region.Region,
		AccountID: identity.AccountId,

		HostnameSuffix:     args.HostnameSuffix,
		Chain:              args.Chain,
		ImageRepositoryURL: args.ProvisionImageRepositoryURL,
		ImageDigest:        args.ProvisionImageDigest,

		SubnetIDs:       net.PrivateSubnetIDs,
		SecurityGroupID: net.LambdaSecurityGroupID,

		DBHost:                  db.Address,
		DBPort:                  db.Port,
		DBMasterSecretArn:       db.MasterSecretArn,
		DBMasterSecretKmsKeyArn: db.MasterSecretKmsKeyID,

		OpenBaoAddress: openBaoAddress,
		PrivateCIDRs:   net.PrivateSubnetCIDRs,
	}, child...)
	if err != nil {
		return nil, err
	}

	// Mints every identity, wallet and password, and creates the per-service
	// databases. Safe to re-run at any time: nothing that already exists is
	// regenerated, which is what protects the funded wallets.
	seedInput, err := phaseInput("seed", args.SeedTrigger)
	if err != nil {
		return nil, err
	}

	seed, err := lambda.NewInvocation(ctx, name+"-seed", &lambda.InvocationArgs{
		FunctionName: minter.FunctionName,
		Input:        pulumi.String(seedInput),
	}, append(child, pulumi.DependsOn([]pulumi.Resource{db}))...)
	if err != nil {
		return nil, err
	}

	vault, err := openbao.New(ctx, name+"-openbao", &openbao.Args{
		Stage:     args.Stage,
		Region:    region.Region,
		AccountID: identity.AccountId,

		Image:       args.OpenBaoImage,
		MaxParallel: args.OpenBaoMaxParallel,
		Hostname:    "ssm." + args.HostnameSuffix,

		ClusterArn:      cluster.Arn,
		VpcID:           net.VpcID,
		SubnetIDs:       net.PrivateSubnetIDs,
		SecurityGroupID: net.ServiceSecurityGroupID,

		KmsKeyID:  seal.KeyID,
		KmsKeyArn: seal.KeyArn,
		SSMPrefix: fmt.Sprintf("/forge-central/%s/openbao", args.Stage),

		ListenerArn:      entry.ListenerArn,
		ListenerPriority: 100,
		Route53ZoneID:    entry.Route53ZoneID,
		AlbDNSName:       entry.DNSName,
		AlbZoneID:        entry.ZoneID,

		NamespaceID:   net.NamespaceID,
		NamespaceName: net.NamespaceName,

		// OpenBao's database is created by the seed phase.
	}, append(child, pulumi.DependsOn([]pulumi.Resource{seed}))...)
	if err != nil {
		return nil, err
	}

	// Initialises OpenBao, mounts KV v2 at forge-central/hilt and the transit
	// engine, and issues hilt's AppRole. The function waits out the task's cold
	// start, so this is slow on the first run of a stage and fast afterwards.
	vaultInput, err := phaseInput("vault", args.VaultTrigger)
	if err != nil {
		return nil, err
	}

	vaultPhase, err := lambda.NewInvocation(ctx, name+"-vault", &lambda.InvocationArgs{
		FunctionName: minter.FunctionName,
		Input:        pulumi.String(vaultInput),
	}, append(child, pulumi.DependsOn([]pulumi.Resource{vault}))...)
	if err != nil {
		return nil, err
	}

	component.ClusterArn = cluster.Arn
	component.VpcID = net.VpcID
	component.PrivateSubnetIDs = net.PrivateSubnetIDs
	component.ServiceSecurityGroupID = net.ServiceSecurityGroupID
	component.NamespaceID = net.NamespaceID
	component.NamespaceName = net.NamespaceName
	component.ListenerArn = entry.ListenerArn
	component.AlbDNSName = entry.DNSName
	component.AlbZoneID = entry.ZoneID
	component.Route53ZoneID = entry.Route53ZoneID

	component.BucketNames = store.BucketNames
	component.BucketArns = store.BucketArns
	component.AllowListTableName = store.AllowListTableName
	component.ProviderInfoTableName = store.ProviderInfoTableName
	component.DynamoDBTableArns = store.TableArns

	component.OpenBaoInternalAddress = vault.InternalAddress
	component.OpenBaoPublicURL = vault.PublicURL

	seedResult := parseResponse(seed.Result)
	component.ServiceDIDs = seedResult.dids()
	component.WalletAddresses = seedResult.addresses()
	component.Databases = seedResult.databases()
	component.CreatedParameters = seedResult.created()
	component.OpenBaoInitialised = parseResponse(vaultPhase.Result).initialised()

	if err := ctx.RegisterResourceOutputs(component, pulumi.Map{
		"clusterArn":  component.ClusterArn,
		"vpcId":       component.VpcID,
		"listenerArn": component.ListenerArn,
	}); err != nil {
		return nil, err
	}

	return component, nil
}

// phaseInput is the event the Lambda receives. Changing the trigger changes the
// input, which is what makes the invocation run again: it is created once and
// re-created when its input differs, exactly as the Terraform resource behaved.
func phaseInput(phase, trigger string) (string, error) {
	encoded, err := json.Marshal(map[string]string{"phase": phase, "trigger": trigger})
	if err != nil {
		return "", fmt.Errorf("marshal %s phase input: %w", phase, err)
	}

	return string(encoded), nil
}

// response is the public material the provision Lambda returns. It mirrors the
// Response type in cmd/provision, which cannot be imported because that package
// is a main. Every field here is safe to read by anyone with state access, which
// is the point.
type response struct {
	DIDs        map[string]string `json:"dids"`
	Addresses   map[string]string `json:"addresses"`
	Databases   []string          `json:"databases"`
	Created     []string          `json:"created"`
	Initialised bool              `json:"initialised"`
}

// parsed reads one field of the response per accessor.
//
// Each accessor decodes the result itself rather than sharing a decoded
// intermediate, because an apply over a struct-typed output would have to be
// written against interface{} and cast back, which is exactly the kind of
// unchecked shape this migration should not introduce.
//
// A malformed or absent result leaves the output empty rather than failing the
// run — Terraform wrapped each of these reads in try() for the same reason. These
// are reports about what happened, not inputs to anything.
type parsed struct {
	result pulumi.StringOutput
}

func parseResponse(result pulumi.StringOutput) parsed {
	return parsed{result: result}
}

// decode never fails: an unreadable result is reported as an empty response.
func decode(raw string) response {
	var decoded response
	if err := json.Unmarshal([]byte(raw), &decoded); err != nil {
		return response{}
	}

	return decoded
}

func (p parsed) dids() pulumi.StringMapOutput {
	return p.result.ApplyT(func(raw string) map[string]string {
		return orEmptyMap(decode(raw).DIDs)
	}).(pulumi.StringMapOutput)
}

func (p parsed) addresses() pulumi.StringMapOutput {
	return p.result.ApplyT(func(raw string) map[string]string {
		return orEmptyMap(decode(raw).Addresses)
	}).(pulumi.StringMapOutput)
}

func (p parsed) databases() pulumi.StringArrayOutput {
	return p.result.ApplyT(func(raw string) []string {
		return orEmptySlice(decode(raw).Databases)
	}).(pulumi.StringArrayOutput)
}

func (p parsed) created() pulumi.StringArrayOutput {
	return p.result.ApplyT(func(raw string) []string {
		return orEmptySlice(decode(raw).Created)
	}).(pulumi.StringArrayOutput)
}

func (p parsed) initialised() pulumi.BoolOutput {
	return p.result.ApplyT(func(raw string) bool {
		return decode(raw).Initialised
	}).(pulumi.BoolOutput)
}

func orEmptyMap(values map[string]string) map[string]string {
	if values == nil {
		return map[string]string{}
	}

	return values
}

func orEmptySlice(values []string) []string {
	if values == nil {
		return []string{}
	}

	return values
}

// deletionWindow gives a protected stage the widest window AWS allows and a
// disposable one the narrowest, since the seal key is the last thing left
// standing after a destroy.
func deletionWindow(protect bool) int {
	if protect {
		return 30
	}

	return 7
}

func insights(enabled bool) string {
	if enabled {
		return "enabled"
	}

	return "disabled"
}

func boolOr(value *bool, fallback bool) bool {
	if value == nil {
		return fallback
	}

	return *value
}
