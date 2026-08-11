// Package kms creates one customer-managed key per stage, sealing OpenBao.
//
// Using it as OpenBao's seal is what removes the unseal key from the design
// entirely. smelt keeps a Shamir key in 1Password and runs a sidecar that polls
// and unseals; here KMS unwraps the barrier key on startup, so a replaced task
// comes back ready with no operator step and no plaintext key anywhere.
//
// SecureString parameters deliberately do not use this key. It dies with the
// stage, and a key in PendingDeletion stops serving decryption at once, so
// every secret the stage ever minted would become unreadable the moment it came
// down. They take the account's AWS-managed SSM key instead, which cannot be
// deleted. What this key protects therefore dies with the stage by design:
// OpenBao's storage lives in the same RDS instance and goes at the same time.
package kms

import (
	"fmt"

	"github.com/pulumi/pulumi-aws/sdk/v7/go/aws/kms"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
)

// Args configures the seal key.
type Args struct {
	Stage string

	// DeletionWindowInDays is how long the key sits in PendingDeletion after a
	// destroy. AWS accepts 7 to 30 and offers no way to delete a key outright.
	// Zero defaults to 30.
	DeletionWindowInDays int
}

// Key is a stage's seal key.
type Key struct {
	pulumi.ResourceState

	KeyID  pulumi.StringOutput
	KeyArn pulumi.StringOutput
}

// New creates the key and its alias.
func New(ctx *pulumi.Context, name string, args *Args, opts ...pulumi.ResourceOption) (*Key, error) {
	if args.Stage == "" {
		return nil, fmt.Errorf("kms: stage is required")
	}
	if args.DeletionWindowInDays == 0 {
		args.DeletionWindowInDays = 30
	}
	if args.DeletionWindowInDays < 7 || args.DeletionWindowInDays > 30 {
		return nil, fmt.Errorf("kms: deletion window is %d days; AWS accepts 7 to 30", args.DeletionWindowInDays)
	}

	component := &Key{}
	if err := ctx.RegisterComponentResource("forge:index:SealKey", name, component, opts...); err != nil {
		return nil, err
	}

	child := []pulumi.ResourceOption{pulumi.Parent(component)}

	key, err := kms.NewKey(ctx, name+"-key", &kms.KeyArgs{
		Description:       pulumi.String(fmt.Sprintf("Forge %s: the OpenBao seal", args.Stage)),
		EnableKeyRotation: pulumi.Bool(true),

		// A destroyed key makes OpenBao's storage permanently unreadable, so a
		// protected stage takes the widest window AWS allows. A stage meant to
		// come apart takes the narrowest, since the key is the last thing left
		// standing after its destroy.
		DeletionWindowInDays: pulumi.Int(args.DeletionWindowInDays),
	}, child...)
	if err != nil {
		return nil, err
	}

	if _, err := kms.NewAlias(ctx, name+"-alias", &kms.AliasArgs{
		Name:        pulumi.String("alias/fc-" + args.Stage),
		TargetKeyId: key.KeyId,
	}, child...); err != nil {
		return nil, err
	}

	component.KeyID = key.KeyId
	component.KeyArn = key.Arn

	if err := ctx.RegisterResourceOutputs(component, pulumi.Map{
		"keyId":  component.KeyID,
		"keyArn": component.KeyArn,
	}); err != nil {
		return nil, err
	}

	return component, nil
}
