package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"

	"github.com/aws/aws-sdk-go-v2/aws"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/iam"
	iamtypes "github.com/aws/aws-sdk-go-v2/service/iam/types"
	"github.com/hashicorp/go-secure-stdlib/parseutil"

	"github.com/fil-forge/infra-central/internal/vaultinit"
)

// Backup key plan actions, which are also what the script prints.
const (
	backupKeyActionMint          = "mint"
	backupKeyActionReissue       = "reissue"
	backupKeyActionSkip          = "skip"
	backupKeyActionNotApplicable = "not-applicable"
)

// applianceBackupKey issues the access key a regional appliance writes its
// backups with.
//
// Each region has its own IAM user, created by Terraform from appliance_regions
// and allowed to write under its own prefix of the stage's backup bucket. The
// key is minted here rather than by Terraform so its secret never lands in
// state, and it is returned wrapped by central OpenBao, the way the unseal
// token is. Like that phase, this one must never be wired to an
// aws_lambda_invocation. See docs/decisions/2026-11-appliance-backup-target.md.
func (d *deps) applianceBackupKey(ctx context.Context, req Request) (*Response, error) {
	if req.Region == "" {
		return nil, fmt.Errorf("a region is required")
	}

	if d.cfg.BackupBucket == "" {
		slog.Info("this stage takes no appliance backups", "region", req.Region)
		return &Response{
			Phase:         "appliance-backup-key",
			DryRun:        !req.Confirm,
			BackupKeyPlan: &BackupKeyPlan{Region: req.Region, Action: backupKeyActionNotApplicable},
		}, nil
	}

	wrapTTL := valueOr(req.WrapTTL, defaultWrapTTL)
	if _, err := parseutil.ParseDurationSecond(wrapTTL); err != nil {
		return nil, fmt.Errorf("--wrap-ttl %q is not a duration openbao accepts: %w", wrapTTL, err)
	}

	awsCfg, err := awsconfig.LoadDefaultConfig(ctx)
	if err != nil {
		return nil, fmt.Errorf("load AWS config: %w", err)
	}
	iamClient := iam.NewFromConfig(awsCfg)

	user := d.cfg.BackupUserPrefix + req.Region
	slog.Info("reading the backup writer's access keys", "region", req.Region, "user", user)
	plan, err := planBackupKey(ctx, iamClient, user, req.Region, req.Reissue)
	if err != nil {
		return nil, err
	}
	plan.Bucket = d.cfg.BackupBucket
	plan.Prefix = backupPrefix(req.Region)
	plan.WrapTTL = wrapTTL

	if !req.Confirm {
		slog.Info("backup key plan prepared", "region", req.Region, "action", plan.Action)
		return &Response{Phase: "appliance-backup-key", DryRun: true, BackupKeyPlan: plan}, nil
	}
	if plan.Action == backupKeyActionSkip {
		slog.Info("the backup writer already has a key, minting nothing", "region", req.Region)
		return &Response{Phase: "appliance-backup-key", BackupKeyPlan: plan}, nil
	}

	bao, err := d.openBaoAsRoot(ctx)
	if err != nil {
		return nil, err
	}
	wrap := func(ctx context.Context, data map[string]any) (string, error) {
		return vaultinit.WrapData(ctx, bao, data, wrapTTL)
	}

	result, err := mintBackupKey(ctx, iamClient, wrap, plan, d.cfg.Region)
	if err != nil {
		return nil, err
	}
	// The node unwraps from outside the VPC, at the same public hostname it
	// unwraps its unseal token from.
	result.UnwrapAddress = "https://ssm." + d.cfg.HostnameSuffix

	return &Response{Phase: "appliance-backup-key", BackupKeyResult: result}, nil
}

// BackupKeyPlan is what the dry run reports. It names keys by ID and never
// carries a secret.
type BackupKeyPlan struct {
	Region string `json:"region"`
	// Action is mint, reissue, skip or not-applicable.
	Action string `json:"action"`
	User   string `json:"user,omitempty"`
	// ExistingKeyIDs are the writer's keys before this run. A reissue deletes
	// all of them.
	ExistingKeyIDs []string `json:"existing_key_ids,omitempty"`
	Bucket         string   `json:"bucket,omitempty"`
	Prefix         string   `json:"prefix,omitempty"`
	WrapTTL        string   `json:"wrap_ttl,omitempty"`
}

// BackupKeyResult carries the wrapped key back to the operator.
//
// WrappingToken exchanges for the secret access key, so it is not safe for
// Terraform state; every other field is the operator's non-secret record.
type BackupKeyResult struct {
	Region        string `json:"region"`
	WrappingToken string `json:"wrapping_token"`
	AccessKeyID   string `json:"access_key_id"`
	Bucket        string `json:"bucket"`
	Prefix        string `json:"prefix"`
	AWSRegion     string `json:"aws_region"`
	WrapTTL       string `json:"wrap_ttl"`
	// UnwrapAddress is where the node exchanges the wrapping token.
	UnwrapAddress string `json:"unwrap_address"`
	// DeletedKeyIDs are the keys a reissue removed.
	DeletedKeyIDs []string `json:"deleted_key_ids,omitempty"`
}

// backupKeyIAM is the slice of IAM this phase calls, and all the Lambda's role
// is granted on the writer users.
type backupKeyIAM interface {
	ListAccessKeys(ctx context.Context, params *iam.ListAccessKeysInput, optFns ...func(*iam.Options)) (*iam.ListAccessKeysOutput, error)
	CreateAccessKey(ctx context.Context, params *iam.CreateAccessKeyInput, optFns ...func(*iam.Options)) (*iam.CreateAccessKeyOutput, error)
	DeleteAccessKey(ctx context.Context, params *iam.DeleteAccessKeyInput, optFns ...func(*iam.Options)) (*iam.DeleteAccessKeyOutput, error)
}

// planBackupKey reads the writer user's keys and decides what to do.
//
// A user that does not exist is refused. Terraform creates one per entry in
// appliance_regions, so a missing user is a region that was never committed or
// has been retired, and a key for it is not something this phase may invent.
func planBackupKey(ctx context.Context, client backupKeyIAM, user, region string, reissue bool) (*BackupKeyPlan, error) {
	out, err := client.ListAccessKeys(ctx, &iam.ListAccessKeysInput{UserName: aws.String(user)})
	var noSuchUser *iamtypes.NoSuchEntityException
	switch {
	case errors.As(err, &noSuchUser):
		return nil, fmt.Errorf(
			"no IAM user %s: add %q to appliance_regions in the stage's terraform.tfvars and merge, which creates the user",
			user, region)
	case err != nil:
		return nil, fmt.Errorf("list the access keys of %s: %w", user, err)
	}

	plan := &BackupKeyPlan{Region: region, User: user}
	for _, key := range out.AccessKeyMetadata {
		plan.ExistingKeyIDs = append(plan.ExistingKeyIDs, aws.ToString(key.AccessKeyId))
	}
	plan.Action = decideBackupKeyAction(len(plan.ExistingKeyIDs) > 0, reissue)
	return plan, nil
}

// decideBackupKeyAction settles what to do about the writer's existing keys.
//
// A user with a key is skipped rather than refused, so the mint script can be
// run for an appliance that is already set up and mint only what it lacks. A
// second key would be a second credential nobody tracks.
func decideBackupKeyAction(hasKey, reissue bool) string {
	switch {
	case !hasKey:
		return backupKeyActionMint
	case reissue:
		return backupKeyActionReissue
	default:
		return backupKeyActionSkip
	}
}

// mintBackupKey creates the writer's access key and wraps it.
//
// A reissue deletes the existing keys first. It is the compromise path, so the
// old key must stop working even if the mint that follows fails; the node then
// fails its uploads loudly until the operator runs the reissue again. Deleting
// first also keeps the user under IAM's limit of two keys.
func mintBackupKey(ctx context.Context, client backupKeyIAM, wrap func(context.Context, map[string]any) (string, error), plan *BackupKeyPlan, awsRegion string) (*BackupKeyResult, error) {
	result := &BackupKeyResult{
		Region:    plan.Region,
		Bucket:    plan.Bucket,
		Prefix:    plan.Prefix,
		AWSRegion: awsRegion,
		WrapTTL:   plan.WrapTTL,
	}

	if plan.Action == backupKeyActionReissue {
		for _, id := range plan.ExistingKeyIDs {
			slog.Warn("deleting the backup writer's previous key", "user", plan.User, "access_key_id", id)
			if err := deleteAccessKey(ctx, client, plan.User, id); err != nil {
				return nil, err
			}
			result.DeletedKeyIDs = append(result.DeletedKeyIDs, id)
		}
	}

	slog.Info("creating the backup writer's access key", "user", plan.User)
	created, err := client.CreateAccessKey(ctx, &iam.CreateAccessKeyInput{UserName: aws.String(plan.User)})
	if err != nil {
		if len(result.DeletedKeyIDs) > 0 {
			return nil, fmt.Errorf(
				"create an access key for %s: %w; its previous keys %v are already deleted, so a re-run mints one without --reissue-backup-key",
				plan.User, err, result.DeletedKeyIDs)
		}
		return nil, fmt.Errorf("create an access key for %s: %w", plan.User, err)
	}
	if created.AccessKey == nil {
		return nil, fmt.Errorf("IAM returned no access key for %s", plan.User)
	}
	keyID := aws.ToString(created.AccessKey.AccessKeyId)

	slog.Info("wrapping the backup key", "user", plan.User, "access_key_id", keyID, "wrap_ttl", plan.WrapTTL)
	wrappingToken, err := wrap(ctx, map[string]any{
		"access_key_id":     keyID,
		"secret_access_key": aws.ToString(created.AccessKey.SecretAccessKey),
		"bucket":            plan.Bucket,
		"prefix":            plan.Prefix,
		"aws_region":        awsRegion,
	})
	if err != nil {
		return nil, discardUnwrappedKey(ctx, client, plan.User, keyID, err)
	}

	// The key ID is logged and the secret is not.
	slog.Info("minted the backup key", "region", plan.Region, "access_key_id", keyID)
	result.WrappingToken = wrappingToken
	result.AccessKeyID = keyID
	return result, nil
}

// discardUnwrappedKey deletes a key that could not be wrapped.
//
// Its secret exists nowhere but in this invocation, so nobody can ever use it,
// and leaving it would make the next run skip a user whose only key is lost.
func discardUnwrappedKey(ctx context.Context, client backupKeyIAM, user, keyID string, wrapErr error) error {
	if err := deleteAccessKey(ctx, client, user, keyID); err != nil {
		// Naming the key is what lets an operator delete it by hand.
		return fmt.Errorf("wrap the backup key: %w, and deleting access key %s of %s failed: %w",
			wrapErr, keyID, user, err)
	}
	return fmt.Errorf("wrap the backup key, so access key %s was deleted: %w", keyID, wrapErr)
}

func deleteAccessKey(ctx context.Context, client backupKeyIAM, user, keyID string) error {
	_, err := client.DeleteAccessKey(ctx, &iam.DeleteAccessKeyInput{
		UserName:    aws.String(user),
		AccessKeyId: aws.String(keyID),
	})
	if err != nil {
		return fmt.Errorf("delete access key %s of %s: %w", keyID, user, err)
	}
	return nil
}

// backupPrefix is the key prefix a region writes under. The writer's policy
// grants nothing outside it.
func backupPrefix(region string) string {
	return region + "/"
}
