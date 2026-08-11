// Bootstrap creates the ECR repositories every stage in one account and region
// pulls its images from.
//
// It is a project of its own because of a chicken-and-egg problem. The platform
// stack requires an image digest, `make publish` cannot push without a
// repository, and the repository cannot be created by the same run that consumes
// the image.
//
// There is one stack per account and region, because an ECR repository serves
// only functions in the same account and region. Adding either means adding a
// stack and a two-line config file — the region and the account it guards.
// Nothing else in the tree is region-aware, so there is no shared list to keep in
// step.
package main

import (
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi/config"

	"github.com/fil-forge/infra-central/pulumi/internal/ecr"
	"github.com/fil-forge/infra-central/pulumi/internal/stack"
)

func main() {
	pulumi.Run(func(ctx *pulumi.Context) error {
		forge := config.New(ctx, "forge-central")

		// A repository created in the wrong account is invisible until a stage's
		// Lambda fails to pull from it, so the stack names the account it belongs
		// to and a mismatch fails at preview time instead.
		provider, err := stack.Provider(ctx, "aws", stack.ProviderArgs{
			Region:  config.New(ctx, "aws").Require("region"),
			Account: stack.Account(forge.Require("account")),
		})
		if err != nil {
			return err
		}

		repositories, err := ecr.New(ctx, "ecr", pulumi.Providers(provider))
		if err != nil {
			return err
		}

		ctx.Export("provisionRepositoryUrl", repositories.ProvisionRepositoryURL)

		return nil
	})
}
