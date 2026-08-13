// Apps builds a stage's six ECS services.
//
// It reads the platform stack for the same stage rather than re-deriving anything,
// so a routine image bump previews in seconds and never touches the database. The
// stack reference is what keeps the two in order: it makes the platform stack's
// outputs a dependency, so this stack cannot run ahead of them.
package main

import (
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi/config"

	"github.com/fil-forge/infra-central/pulumi/internal/apps"
	"github.com/fil-forge/infra-central/pulumi/internal/chain"
	"github.com/fil-forge/infra-central/pulumi/internal/platform/storage"
	"github.com/fil-forge/infra-central/pulumi/internal/stack"
)

func main() {
	pulumi.Run(func(ctx *pulumi.Context) error {
		// The same stack name as the platform stack this reads, which is what makes
		// the pair a stage.
		stage := ctx.Stack()

		forge := config.New(ctx, "forge-central")

		provider, err := stack.Provider(ctx, "aws", stack.ProviderArgs{
			Region:  config.New(ctx, "aws").Require("region"),
			Account: stack.Account(forge.Require("account")),
			DefaultTags: map[string]string{
				"Project": "forge-central",
				"Stage":   stage,
			},
		})
		if err != nil {
			return err
		}

		platform, err := stack.Read(ctx, "platform", stack.Name(stack.PlatformProject, stage))
		if err != nil {
			return err
		}

		var digests apps.Digests
		forge.RequireObject("imageDigests", &digests)

		hostnameSuffix := platform.String("hostnameSuffix")

		built, err := apps.New(ctx, "apps", &apps.Args{
			Stage:          stage,
			HostnameSuffix: hostnameSuffix,

			ClusterArn:      platform.String("clusterArn"),
			VpcID:           platform.String("vpcId"),
			SubnetIDs:       platform.StringArray("privateSubnetIds"),
			SecurityGroupID: platform.String("serviceSecurityGroupId"),

			ListenerArn:   platform.String("listenerArn"),
			Route53ZoneID: platform.String("route53ZoneId"),
			AlbDNSName:    platform.String("albDnsName"),
			AlbZoneID:     platform.String("albZoneId"),

			NamespaceID:   platform.String("namespaceId"),
			NamespaceName: platform.String("namespaceName"),

			BucketNames: bucketNames(platform),
			BucketArns:  platform.StringArray("bucketArns"),

			AllowListTableName:    platform.String("allowListTableName"),
			ProviderInfoTableName: platform.String("providerInfoTableName"),
			DynamoDBTableArns:     platform.StringArray("dynamodbTableArns"),

			OpenBaoInternalAddress: platform.String("openbaoInternalAddress"),

			// Neither service is deployed yet. The delegator validates proofs
			// signed by these DIDs at startup, so the names have to be settled even
			// though nothing answers at them.
			IndexerDID:  webDID("indexer", hostnameSuffix),
			EtrackerDID: webDID("etracker", hostnameSuffix),

			ImageDigests: digests,

			// One home per stage: the platform stack owns it, this one reads it.
			Chain: chain.InputsFrom(platform.Output("chain")),

			AllowProvisionWithoutPaymentPlan: forge.GetBool("allowProvisionWithoutPaymentPlan"),

			LogLevel: forge.Get("logLevel"),
		}, pulumi.Providers(provider))
		if err != nil {
			return err
		}

		ctx.Export("serviceUrls", built.ServiceURLs)
		ctx.Export("serviceDids", built.ServiceDIDs)
		ctx.Export("plcInternalUrl", built.PlcInternalURL)
		ctx.Export("logGroups", built.LogGroups)

		return nil
	})
}

// bucketNames turns the platform stack's bucket map into one keyed by the logical
// names sprue's settings are built from.
//
// The keys come from the storage package rather than being written out here, so a
// bucket added there cannot be missed on this side.
func bucketNames(platform *stack.Reference) pulumi.StringMap {
	published := platform.StringMap("bucketNames")

	names := pulumi.StringMap{}
	for _, logical := range storage.Buckets {
		names[logical] = published.MapIndex(pulumi.String(logical))
	}

	return names
}

// webDID names a service that is addressed by did:web but has no deployment here.
func webDID(service string, suffix pulumi.StringOutput) pulumi.StringOutput {
	return suffix.ApplyT(func(suffix string) string {
		return "did:web:" + service + "." + suffix
	}).(pulumi.StringOutput)
}
