// Platform builds everything in a stage that changes rarely: VPC, RDS, S3,
// DynamoDB, ALB, OpenBao and the provision Lambda.
//
// One project, one stack per stage. What differs between stages is the stack's
// configuration and nothing else, which is what keeps two stages from quietly
// ceasing to resemble each other.
//
// The apps stack for the same stage reads this stack's outputs, so this one has to
// be up first.
package main

import (
	"fmt"

	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi/config"

	"github.com/fil-forge/infra-central/pulumi/internal/chain"
	"github.com/fil-forge/infra-central/pulumi/internal/platform"
	"github.com/fil-forge/infra-central/pulumi/internal/stack"
)

func main() {
	pulumi.Run(func(ctx *pulumi.Context) error {
		// The stack's own name is the stage. Nothing else names it, so the stage
		// label and the state it refers to cannot come apart.
		stage := ctx.Stack()

		forge := config.New(ctx, "forge-central")
		region := config.New(ctx, "aws").Require("region")
		account := stack.Account(forge.Require("account"))

		accountID, err := account.ID()
		if err != nil {
			return err
		}

		provider, err := stack.Provider(ctx, "aws", stack.ProviderArgs{
			Region:  region,
			Account: account,
			DefaultTags: map[string]string{
				"Project": "forge-central",
				"Stage":   stage,
			},
		})
		if err != nil {
			return err
		}

		var chainConfig chain.Config
		forge.RequireObject("chain", &chainConfig)

		built, err := platform.New(ctx, "platform", &platform.Args{
			Stage:          stage,
			ZoneName:       forge.Require("zoneName"),
			HostnameSuffix: forge.Require("hostnameSuffix"),

			// The repository the bootstrap stack for this account and region
			// created. Derived rather than read from that stack's outputs: a
			// Lambda can pull only from its own account and region, so those two
			// values are the whole address.
			ProvisionImageRepositoryURL: fmt.Sprintf("%s.dkr.ecr.%s.amazonaws.com/%s", accountID, region, stack.ProvisionRepositoryName),
			ProvisionImageDigest:        forge.Require("provisionImageDigest"),

			Chain: chainConfig,

			DBInstanceClass:       forge.Get("dbInstanceClass"),
			DBAllocatedStorage:    forge.GetInt("dbAllocatedStorage"),
			DBBackupRetentionDays: forge.GetInt("dbBackupRetentionDays"),
			DBMultiAZ:             optionalBool(forge, "dbMultiAz"),

			ProtectStatefulResources: optionalBool(forge, "protectStatefulResources"),

			OpenBaoImage:       forge.Get("openbaoImage"),
			OpenBaoMaxParallel: forge.GetInt("openbaoMaxParallel"),

			ContainerInsights: forge.GetBool("containerInsights"),

			SeedTrigger:  forge.Get("seedTrigger"),
			VaultTrigger: forge.Get("vaultTrigger"),
		}, pulumi.Providers(provider))
		if err != nil {
			return err
		}

		exportPlatform(ctx, built)

		return nil
	})
}

// exportPlatform publishes what the apps stack reads, then the public material the
// provision Lambda returned.
//
// Terraform re-exported these wholesale as one object, because tfe_outputs could
// only read a workspace's outputs as a map and every derived value inherited the
// sensitivity of the whole. A stack reference reads outputs one at a time, so they
// are published flat and each keeps its own name.
func exportPlatform(ctx *pulumi.Context, built *platform.Platform) {
	ctx.Export("stage", pulumi.String(built.Stage))
	ctx.Export("hostnameSuffix", pulumi.String(built.HostnameSuffix))

	ctx.Export("clusterArn", built.ClusterArn)
	ctx.Export("vpcId", built.VpcID)
	ctx.Export("privateSubnetIds", built.PrivateSubnetIDs)
	ctx.Export("serviceSecurityGroupId", built.ServiceSecurityGroupID)
	ctx.Export("namespaceId", built.NamespaceID)
	ctx.Export("namespaceName", built.NamespaceName)
	ctx.Export("listenerArn", built.ListenerArn)
	ctx.Export("albDnsName", built.AlbDNSName)
	ctx.Export("albZoneId", built.AlbZoneID)
	ctx.Export("route53ZoneId", built.Route53ZoneID)

	ctx.Export("bucketNames", built.BucketNames)
	ctx.Export("bucketArns", built.BucketArns)
	ctx.Export("allowListTableName", built.AllowListTableName)
	ctx.Export("providerInfoTableName", built.ProviderInfoTableName)
	ctx.Export("dynamodbTableArns", built.DynamoDBTableArns)

	ctx.Export("openbaoInternalAddress", built.OpenBaoInternalAddress)
	ctx.Export("openbaoPublicUrl", built.OpenBaoPublicURL)

	// Owned here so the apps stack reads it rather than keeping a second copy.
	ctx.Export("chain", built.Chain.ToMap())

	// did:key per service, stable across restarts.
	ctx.Export("serviceDids", built.ServiceDIDs)

	// Fund these with tFIL, and the payer with USDFC.
	ctx.Export("walletAddresses", built.WalletAddresses)

	ctx.Export("databases", built.Databases)

	// Empty on a steady-state run. A non-empty list after a run means something
	// was regenerated; check it before assuming a wallet is intact.
	ctx.Export("createdParameters", built.CreatedParameters)

	ctx.Export("openbaoInitialised", built.OpenBaoInitialised)
}

// optionalBool distinguishes "not set" from "set to false", which a plain GetBool
// cannot. Deletion protection and multi-AZ both default to on, so an absent value
// has to mean the safe answer rather than the zero one.
func optionalBool(cfg *config.Config, key string) *bool {
	value, err := cfg.TryBool(key)
	if err != nil {
		return nil
	}

	return &value
}
