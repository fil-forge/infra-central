package main

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/iam"
	iamtypes "github.com/aws/aws-sdk-go-v2/service/iam/types"
)

// A user with a key is skipped so the mint script can be re-run for an
// appliance that is already set up, and only a reissue replaces the key.
func TestPlanBackupKeyAction(t *testing.T) {
	cases := []struct {
		desc    string
		keys    []string
		reissue bool
		want    string
	}{
		{desc: "the user has no key", want: backupKeyActionMint},
		{desc: "the user has no key and reissue was asked for anyway", reissue: true, want: backupKeyActionMint},
		{desc: "the user has a key", keys: []string{"AKIAOLD"}, want: backupKeyActionSkip},
		{desc: "the user has a key and reissue was asked for", keys: []string{"AKIAOLD"}, reissue: true, want: backupKeyActionReissue},
	}

	for _, c := range cases {
		t.Run(c.desc, func(t *testing.T) {
			plan, err := planBackupKey(context.Background(), &fakeIAM{keys: c.keys}, "forge-nodes-backup-staging-eu-central-3", "eu-central-3", c.reissue)
			if err != nil {
				t.Fatal(err)
			}
			if plan.Action != c.want {
				t.Errorf("action = %q, want %q", plan.Action, c.want)
			}
		})
	}
}

func TestPlanBackupKeyReportsTheExistingKeyIDs(t *testing.T) {
	plan, err := planBackupKey(context.Background(), &fakeIAM{keys: []string{"AKIA1", "AKIA2"}}, "u", "eu-central-3", false)
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"AKIA1", "AKIA2"}; !reflect.DeepEqual(plan.ExistingKeyIDs, want) {
		t.Errorf("existing keys = %v, want %v", plan.ExistingKeyIDs, want)
	}
}

// Terraform creates one user per committed region, so a missing user is a
// region label that was never merged, and the error says how to fix that.
func TestPlanBackupKeyRefusesAMissingUser(t *testing.T) {
	_, err := planBackupKey(context.Background(), &fakeIAM{missingUser: true}, "u", "eu-central-3", false)
	if err == nil || !strings.Contains(err.Error(), "appliance_regions") {
		t.Fatalf("planBackupKey() = %v, want an error pointing at appliance_regions", err)
	}
}

func TestPlanBackupKeyReturnsAListFailure(t *testing.T) {
	_, err := planBackupKey(context.Background(), &fakeIAM{listErr: errors.New("throttled")}, "u", "eu-central-3", false)
	if err == nil || !strings.Contains(err.Error(), "throttled") {
		t.Fatalf("planBackupKey() = %v, want the list failure", err)
	}
}

// A reissue is the compromise path, so the old key has to be gone before the
// new one exists, whatever happens to the mint after it.
func TestMintBackupKeyDeletesTheOldKeysBeforeCreatingOnReissue(t *testing.T) {
	client := &fakeIAM{keys: []string{"AKIAOLD"}}
	plan := testBackupKeyPlan(backupKeyActionReissue, "AKIAOLD")

	if _, err := mintBackupKey(context.Background(), client, wrapInto(nil), plan, "us-east-2"); err != nil {
		t.Fatal(err)
	}
	if want := []string{"delete AKIAOLD", "create"}; !reflect.DeepEqual(client.calls, want) {
		t.Errorf("IAM calls = %v, want %v", client.calls, want)
	}
}

func TestMintBackupKeyLeavesExistingKeysAloneOnAMint(t *testing.T) {
	client := &fakeIAM{}

	if _, err := mintBackupKey(context.Background(), client, wrapInto(nil), testBackupKeyPlan(backupKeyActionMint), "us-east-2"); err != nil {
		t.Fatal(err)
	}
	if want := []string{"create"}; !reflect.DeepEqual(client.calls, want) {
		t.Errorf("IAM calls = %v, want %v", client.calls, want)
	}
}

// The node stores the key pair and checks the other three against its
// node.env, so these five names are a contract with infra-nodes.
func TestMintBackupKeyWrapsTheKeyWithItsTarget(t *testing.T) {
	var wrapped map[string]any

	_, err := mintBackupKey(context.Background(), &fakeIAM{}, wrapInto(&wrapped), testBackupKeyPlan(backupKeyActionMint), "us-east-2")
	if err != nil {
		t.Fatal(err)
	}

	want := map[string]any{
		"access_key_id":     "AKIANEW",
		"secret_access_key": "secret-new",
		"bucket":            "forge-nodes-backups-staging-654654381893",
		"prefix":            "eu-central-3/",
		"aws_region":        "us-east-2",
	}
	if !reflect.DeepEqual(wrapped, want) {
		t.Errorf("wrapped = %v, want %v", wrapped, want)
	}
}

// The secret is in the wrapped payload and nowhere in the result.
func TestMintBackupKeyReturnsOnlyTheWrappingTokenAndPublicFields(t *testing.T) {
	result, err := mintBackupKey(context.Background(), &fakeIAM{}, wrapInto(nil), testBackupKeyPlan(backupKeyActionMint), "us-east-2")
	if err != nil {
		t.Fatal(err)
	}

	want := &BackupKeyResult{
		Region:        "eu-central-3",
		WrappingToken: "wrap-1",
		AccessKeyID:   "AKIANEW",
		Bucket:        "forge-nodes-backups-staging-654654381893",
		Prefix:        "eu-central-3/",
		AWSRegion:     "us-east-2",
		WrapTTL:       "24h",
	}
	if !reflect.DeepEqual(result, want) {
		t.Errorf("result = %+v, want %+v", result, want)
	}
}

// A key whose secret was never wrapped is a key nobody holds, and leaving it
// would make the next run skip a user whose only key is lost.
func TestMintBackupKeyDeletesAKeyItCouldNotWrap(t *testing.T) {
	client := &fakeIAM{}

	_, err := mintBackupKey(context.Background(), client, failingWrap, testBackupKeyPlan(backupKeyActionMint), "us-east-2")
	if err == nil {
		t.Fatal("mintBackupKey() = nil, want the wrap error")
	}
	if want := []string{"create", "delete AKIANEW"}; !reflect.DeepEqual(client.calls, want) {
		t.Errorf("IAM calls = %v, want %v", client.calls, want)
	}
}

// An operator who has to delete the key by hand needs its ID.
func TestMintBackupKeyNamesTheKeyWhenDeletingItAlsoFails(t *testing.T) {
	client := &fakeIAM{deleteErr: errors.New("access denied")}

	_, err := mintBackupKey(context.Background(), client, failingWrap, testBackupKeyPlan(backupKeyActionMint), "us-east-2")
	if err == nil || !strings.Contains(err.Error(), "AKIANEW") {
		t.Fatalf("mintBackupKey() = %v, want an error naming access key AKIANEW", err)
	}
}

// A reissue that deleted the old key and then failed to create one has left
// the node with nothing, and the operator has to know a plain re-run fixes it.
func TestMintBackupKeyNamesTheDeletedKeysWhenTheCreateFails(t *testing.T) {
	client := &fakeIAM{keys: []string{"AKIAOLD"}, createErr: errors.New("limit exceeded")}

	_, err := mintBackupKey(context.Background(), client, wrapInto(nil), testBackupKeyPlan(backupKeyActionReissue, "AKIAOLD"), "us-east-2")
	if err == nil || !strings.Contains(err.Error(), "AKIAOLD") {
		t.Fatalf("mintBackupKey() = %v, want an error naming the deleted key AKIAOLD", err)
	}
}

// Dev takes no backups, and the mint script runs this phase there too.
func TestApplianceBackupKeyIsNotApplicableWithoutABucket(t *testing.T) {
	d := &deps{cfg: config{Stage: "dev"}}

	resp, err := d.applianceBackupKey(context.Background(), Request{Phase: "appliance-backup-key", Region: "us-east-9", Confirm: true})
	if err != nil {
		t.Fatal(err)
	}
	if resp.BackupKeyPlan.Action != backupKeyActionNotApplicable {
		t.Errorf("action = %q, want %q", resp.BackupKeyPlan.Action, backupKeyActionNotApplicable)
	}
}

// Terraform sets the bucket and the user prefix together, so one without the
// other is a wiring mistake to stop on.
func TestLoadConfigRefusesHalfTheBackupSettings(t *testing.T) {
	for name, value := range map[string]string{
		"FORGE_STAGE":                 "staging",
		"FORGE_DB_HOST":               "db",
		"FORGE_DB_MASTER_SECRET_ARN":  "arn",
		"FORGE_HOSTNAME_SUFFIX":       "staging.fil-forge.com",
		"FORGE_INGOT_HOSTNAME_SUFFIX": "staging.filonecontent.com",
		"FORGE_BACKUP_BUCKET":         "forge-nodes-backups-staging-654654381893",
		"FORGE_BACKUP_USER_PREFIX":    "",
	} {
		t.Setenv(name, value)
	}

	_, err := loadConfig()
	if err == nil || !strings.Contains(err.Error(), "FORGE_BACKUP_USER_PREFIX") {
		t.Fatalf("loadConfig() = %v, want an error naming FORGE_BACKUP_USER_PREFIX", err)
	}
}

func testBackupKeyPlan(action string, existing ...string) *BackupKeyPlan {
	return &BackupKeyPlan{
		Region:         "eu-central-3",
		Action:         action,
		User:           "forge-nodes-backup-staging-eu-central-3",
		ExistingKeyIDs: existing,
		Bucket:         "forge-nodes-backups-staging-654654381893",
		Prefix:         "eu-central-3/",
		WrapTTL:        "24h",
	}
}

// wrapInto returns a wrap function that records what it was given and answers
// with a fixed wrapping token.
func wrapInto(dst *map[string]any) func(context.Context, map[string]any) (string, error) {
	return func(_ context.Context, data map[string]any) (string, error) {
		if dst != nil {
			*dst = data
		}
		return "wrap-1", nil
	}
}

func failingWrap(context.Context, map[string]any) (string, error) {
	return "", errors.New("openbao is sealed")
}

// fakeIAM answers the three IAM calls the phase makes and records the writes.
type fakeIAM struct {
	keys        []string
	missingUser bool
	listErr     error
	createErr   error
	deleteErr   error

	calls []string
}

func (f *fakeIAM) ListAccessKeys(_ context.Context, _ *iam.ListAccessKeysInput, _ ...func(*iam.Options)) (*iam.ListAccessKeysOutput, error) {
	if f.missingUser {
		return nil, &iamtypes.NoSuchEntityException{Message: aws.String("The user cannot be found.")}
	}
	if f.listErr != nil {
		return nil, f.listErr
	}
	out := &iam.ListAccessKeysOutput{}
	for _, id := range f.keys {
		out.AccessKeyMetadata = append(out.AccessKeyMetadata, iamtypes.AccessKeyMetadata{AccessKeyId: aws.String(id)})
	}
	return out, nil
}

func (f *fakeIAM) CreateAccessKey(_ context.Context, _ *iam.CreateAccessKeyInput, _ ...func(*iam.Options)) (*iam.CreateAccessKeyOutput, error) {
	f.calls = append(f.calls, "create")
	if f.createErr != nil {
		return nil, f.createErr
	}
	return &iam.CreateAccessKeyOutput{AccessKey: &iamtypes.AccessKey{
		AccessKeyId:     aws.String("AKIANEW"),
		SecretAccessKey: aws.String("secret-new"),
	}}, nil
}

func (f *fakeIAM) DeleteAccessKey(_ context.Context, in *iam.DeleteAccessKeyInput, _ ...func(*iam.Options)) (*iam.DeleteAccessKeyOutput, error) {
	f.calls = append(f.calls, "delete "+aws.ToString(in.AccessKeyId))
	if f.deleteErr != nil {
		return nil, f.deleteErr
	}
	return &iam.DeleteAccessKeyOutput{}, nil
}
