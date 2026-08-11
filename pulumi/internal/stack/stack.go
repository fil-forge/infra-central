// Package stack holds the wiring every program in this project repeats: building
// the AWS provider with its account guard, and reading typed values back out of
// another stack's outputs.
//
// The provider is built in code rather than declared in each stack's
// configuration so the account guard comes from the constants package. A stack
// says which account it belongs to by name; the number it maps to is not a value
// anyone should be able to mistype into a YAML file.
package stack

import (
	"fmt"

	"github.com/pulumi/pulumi-aws/sdk/v7/go/aws"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"

	"github.com/fil-forge/infra-central/pulumi/internal/constants"
)

// Account names which AWS account a stack applies to.
type Account string

const (
	// Nonprod is filone-sandbox, holding every non-prod stage.
	Nonprod Account = "nonprod"

	// Prod is filone-production.
	Prod Account = "prod"
)

// ID returns the account number, and rejects anything that is neither.
func (a Account) ID() (string, error) {
	switch a {
	case Nonprod:
		return constants.NonprodAccountID, nil
	case Prod:
		return constants.ProdAccountID, nil
	default:
		return "", fmt.Errorf("account is %q; it has to be %q or %q", string(a), Nonprod, Prod)
	}
}

// ProviderArgs configures the provider.
type ProviderArgs struct {
	Region  string
	Account Account

	// DefaultTags is applied to every resource the provider creates. The
	// bootstrap stacks pass none, matching the Terraform provider block they
	// replace.
	DefaultTags map[string]string
}

// Provider builds the AWS provider for a stack.
//
// The account guard is the point. Credentials for another account would otherwise
// create a second, quietly working copy of the stage there; naming the account the
// stack belongs to fails the preview instead.
func Provider(ctx *pulumi.Context, name string, args ProviderArgs) (*aws.Provider, error) {
	if args.Region == "" {
		return nil, fmt.Errorf("provider: region is required; set aws:region for this stack")
	}

	accountID, err := args.Account.ID()
	if err != nil {
		return nil, fmt.Errorf("provider: %w", err)
	}

	providerArgs := &aws.ProviderArgs{
		Region:            pulumi.String(args.Region),
		AllowedAccountIds: pulumi.StringArray{pulumi.String(accountID)},
	}

	if len(args.DefaultTags) > 0 {
		tags := pulumi.StringMap{}
		for key, value := range args.DefaultTags {
			tags[key] = pulumi.String(value)
		}

		providerArgs.DefaultTags = &aws.ProviderDefaultTagsArgs{Tags: tags}
	}

	return aws.NewProvider(ctx, name, providerArgs)
}

// AccountID returns the account number a stack's Account maps to, for the callers
// that need to build an ARN or an ECR URL rather than a provider.
func AccountID(account Account) (string, error) {
	return account.ID()
}

// --- reading another stack's outputs --------------------------------------

// Reference is another stack's outputs, with typed readers for the shapes this
// project exports. It replaces the tfe_outputs data source.
//
// Terraform had to reach for nonsensitive_values there, because tfe_outputs
// marked the whole map sensitive and the taint spread to everything derived from
// it. Nothing the platform stack exports is a secret — ARNs, subnet ids and
// hostnames — and Pulumi keeps each output's own secretness, so there is nothing
// to strip here.
type Reference struct {
	ref *pulumi.StackReference
}

// Read looks up a stack by its fully qualified name, e.g.
// Filecoin_Foundation/forge-central-platform/dev.
func Read(ctx *pulumi.Context, name, stackName string, opts ...pulumi.ResourceOption) (*Reference, error) {
	ref, err := pulumi.NewStackReference(ctx, name, &pulumi.StackReferenceArgs{
		Name: pulumi.String(stackName),
	}, opts...)
	if err != nil {
		return nil, fmt.Errorf("read stack %s: %w", stackName, err)
	}

	return &Reference{ref: ref}, nil
}

// Name is the fully qualified name of a stack in this project's organization.
func Name(project, stackName string) string {
	return fmt.Sprintf("%s/%s/%s", constants.Organization, project, stackName)
}

// String reads a string output.
func (r *Reference) String(key string) pulumi.StringOutput {
	return r.ref.GetStringOutput(pulumi.String(key))
}

// Output reads an output of any shape, for the callers that decode it themselves.
func (r *Reference) Output(key string) pulumi.Output {
	return r.ref.GetOutput(pulumi.String(key))
}

// StringArray reads a list-of-strings output.
func (r *Reference) StringArray(key string) pulumi.StringArrayOutput {
	return r.Output(key).ApplyT(func(raw interface{}) ([]string, error) {
		items, ok := raw.([]interface{})
		if !ok {
			return nil, fmt.Errorf("stack output %s is a %T, want a list", key, raw)
		}

		values := make([]string, 0, len(items))
		for index, item := range items {
			value, ok := item.(string)
			if !ok {
				return nil, fmt.Errorf("stack output %s[%d] is a %T, want a string", key, index, item)
			}
			values = append(values, value)
		}

		return values, nil
	}).(pulumi.StringArrayOutput)
}

// StringMap reads a map-of-strings output.
func (r *Reference) StringMap(key string) pulumi.StringMapOutput {
	return r.Output(key).ApplyT(func(raw interface{}) (map[string]string, error) {
		object, ok := raw.(map[string]interface{})
		if !ok {
			return nil, fmt.Errorf("stack output %s is a %T, want an object", key, raw)
		}

		values := make(map[string]string, len(object))
		for name, item := range object {
			value, ok := item.(string)
			if !ok {
				return nil, fmt.Errorf("stack output %s[%q] is a %T, want a string", key, name, item)
			}
			values[name] = value
		}

		return values, nil
	}).(pulumi.StringMapOutput)
}
