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
//
// Repositories live under the `forge-central/` prefix, one per image. A repository
// per image is what makes per-image push permissions, lifecycle policies and tag
// mutability possible; a single shared repository distinguished by tag forfeits all
// three. There is one image today, so this program is short.
package main

import (
	"github.com/pulumi/pulumi-aws/sdk/v7/go/aws/ecr"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi/config"

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

		// The repository holding the provision Lambda image.
		//
		// One instance per account *and* region. ECR repositories are regional,
		// Lambda pulls an image only from ECR in the same region as the function,
		// and a pull from another account additionally needs a repository policy
		// that nothing here creates. Stages sharing an account and a region share
		// this repository: they pin different digests, so they do not interfere.
		//
		// The repository name is the same everywhere, which is what lets a stage
		// derive its image URL from its own account and region.
		//
		// Nothing in this repository is tagged. `make publish` pushes by digest, a
		// stage pins that digest, and the Lambda is deployed from it. IMMUTABLE
		// therefore changes no behaviour today and only rejects a tag pushed by
		// hand, which is the right answer for a repository whose only reference is
		// a digest.
		//
		// A repository for a service image deployed by tag needs a deliberate
		// decision instead of this one: there the tag decides what runs, so it has
		// to be immutable, with an exclusion filter for any rolling tag a stage
		// follows.
		provision, err := ecr.NewRepository(ctx, "provision", &ecr.RepositoryArgs{
			Name:               pulumi.String(stack.ProvisionRepositoryName),
			ImageTagMutability: pulumi.String("IMMUTABLE"),
			ImageScanningConfiguration: &ecr.RepositoryImageScanningConfigurationArgs{
				ScanOnPush: pulumi.Bool(true),
			},
		}, pulumi.Provider(provider))
		if err != nil {
			return err
		}

		// No lifecycle policy on purpose. Every image here is untagged, including
		// the one each stage pins, so any expiry rule ECR can express would
		// eventually delete a running function's image, and Lambda cannot recover
		// from that. The images are a few tens of MB and a dev iteration loop is
		// the only thing that grows the count, so prune by hand when it bothers
		// you, checking each digest against the stages that pin one:
		//
		//   aws ecr list-images --repository-name forge-central/provision

		// What `make publish` pushes to. Stages derive the same URL from their own
		// account and region rather than reading it here, so nothing consumes this.
		ctx.Export("provisionRepositoryUrl", provision.RepositoryUrl)

		return nil
	})
}
