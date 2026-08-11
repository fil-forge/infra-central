// Package ecr holds every ECR repository this project publishes to, one
// resource per image.
//
// Repositories live under the `forge-central/` prefix. A repository per image is
// what makes per-image push permissions, lifecycle policies and tag mutability
// possible; a single shared repository distinguished by tag forfeits all three.
package ecr

import (
	"github.com/pulumi/pulumi-aws/sdk/v7/go/aws/ecr"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"

	"github.com/fil-forge/infra-central/pulumi/internal/constants"
)

// Repositories is what a bootstrap stack creates.
type Repositories struct {
	pulumi.ResourceState

	// ProvisionRepositoryURL is what `make publish` pushes to. Stages derive the
	// same URL from their own account and region rather than reading it here, so
	// nothing consumes this output.
	ProvisionRepositoryURL pulumi.StringOutput
}

// New creates the repositories for one account and region.
//
// There is one bootstrap stack per account *and* region. ECR repositories are
// regional, Lambda pulls an image only from ECR in the same region as the
// function, and a pull from another account additionally needs a repository
// policy that nothing here creates. Stages sharing an account and a region share
// this repository: they pin different digests, so they do not interfere.
//
// The repository name is the same everywhere, which is what lets a stage derive
// its image URL from its own account and region.
func New(ctx *pulumi.Context, name string, opts ...pulumi.ResourceOption) (*Repositories, error) {
	component := &Repositories{}
	if err := ctx.RegisterComponentResource("forge:index:EcrRepositories", name, component, opts...); err != nil {
		return nil, err
	}

	child := []pulumi.ResourceOption{pulumi.Parent(component)}

	// The repository holding the provision Lambda image.
	//
	// Nothing in this repository is tagged. `make publish` pushes by digest, a
	// stage pins that digest, and the Lambda is deployed from it. IMMUTABLE
	// therefore changes no behaviour today and only rejects a tag pushed by
	// hand, which is the right answer for a repository whose only reference is a
	// digest.
	//
	// A repository for a service image deployed by tag needs a deliberate
	// decision instead of this one: there the tag decides what runs, so it has
	// to be immutable, with an exclusion filter for any rolling tag a stage
	// follows.
	provision, err := ecr.NewRepository(ctx, name+"-provision", &ecr.RepositoryArgs{
		Name:               pulumi.String(constants.ProvisionRepositoryName),
		ImageTagMutability: pulumi.String("IMMUTABLE"),
		ImageScanningConfiguration: &ecr.RepositoryImageScanningConfigurationArgs{
			ScanOnPush: pulumi.Bool(true),
		},
	}, child...)
	if err != nil {
		return nil, err
	}

	// No lifecycle policy on purpose. Every image here is untagged, including
	// the one each stage pins, so any expiry rule ECR can express would
	// eventually delete a running function's image, and Lambda cannot recover
	// from that. The images are a few tens of MB and a dev iteration loop is the
	// only thing that grows the count, so prune by hand when it bothers you,
	// checking each digest against the stages that pin one:
	//
	//   aws ecr list-images --repository-name forge-central/provision

	component.ProvisionRepositoryURL = provision.RepositoryUrl

	if err := ctx.RegisterResourceOutputs(component, pulumi.Map{
		"provisionRepositoryUrl": component.ProvisionRepositoryURL,
	}); err != nil {
		return nil, err
	}

	return component, nil
}
