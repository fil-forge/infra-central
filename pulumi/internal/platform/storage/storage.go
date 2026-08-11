// Package storage creates the object and key-value stores two services need,
// replacing smelt's MinIO and local DynamoDB.
//
// Sprue reaches S3 through its task role rather than static credentials: the
// apps stack sets its storage.s3.endpoint empty, so the AWS default credential
// chain applies. That removes the MinIO root user and password from the design
// entirely.
package storage

import (
	"fmt"

	"github.com/pulumi/pulumi-aws/sdk/v7/go/aws/dynamodb"
	"github.com/pulumi/pulumi-aws/sdk/v7/go/aws/s3"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
)

// Buckets are sprue's three. Names come from its defaults; the stage prefix and
// account suffix make them globally unique.
//
// A slice rather than a set, so the bucket ARN list below has a fixed order and
// the IAM policy built from it does not churn.
//
// Exported because the apps stack reads the bucket-name map by these keys, and a
// key spelled differently on the two sides would hand sprue an empty bucket name.
var Buckets = []string{"agent-message", "delegation", "upload-shards"}

// Args configures the stores.
type Args struct {
	Stage string

	// AccountID suffixes each bucket name, which has to be globally unique.
	AccountID string

	// ForceDestroy deletes each bucket's contents along with the bucket. Set on
	// non-prod stages, which have to come apart cleanly.
	ForceDestroy bool

	// PointInTimeRecovery turns on continuous backups on the delegator's tables.
	// The allow list gates which storage providers may register, so losing it
	// costs a re-approval of every provider; a stage that is meant to be thrown
	// away does not pay for that.
	PointInTimeRecovery bool
}

// Storage is a stage's buckets and tables.
type Storage struct {
	pulumi.ResourceState

	// BucketNames maps a logical bucket name to the real one, e.g.
	// agent-message => fc-dev-agent-message-123456789012.
	BucketNames pulumi.StringMap
	BucketArns  pulumi.StringArray

	AllowListTableName    pulumi.StringOutput
	ProviderInfoTableName pulumi.StringOutput
	TableArns             pulumi.StringArray
}

// New creates the buckets and the delegator's two tables.
func New(ctx *pulumi.Context, name string, args *Args, opts ...pulumi.ResourceOption) (*Storage, error) {
	if args.Stage == "" || args.AccountID == "" {
		return nil, fmt.Errorf("storage: stage and account id are both required")
	}

	component := &Storage{BucketNames: pulumi.StringMap{}}
	if err := ctx.RegisterComponentResource("forge:index:Storage", name, component, opts...); err != nil {
		return nil, err
	}

	child := []pulumi.ResourceOption{pulumi.Parent(component)}
	fullName := "fc-" + args.Stage

	for _, logical := range Buckets {
		bucketName := fmt.Sprintf("%s-%s-%s", fullName, logical, args.AccountID)

		bucket, err := s3.NewBucket(ctx, fmt.Sprintf("%s-%s", name, logical), &s3.BucketArgs{
			Bucket: pulumi.String(bucketName),

			// Objects here are written by sprue and reproducible from its own
			// state, so a non-prod stage empties its buckets on destroy rather
			// than failing and leaving them behind for someone to purge by hand.
			ForceDestroy: pulumi.Bool(args.ForceDestroy),

			Tags: pulumi.StringMap{"Name": pulumi.String(fullName + "-" + logical)},
		}, child...)
		if err != nil {
			return nil, err
		}

		if _, err := s3.NewBucketPublicAccessBlock(ctx, fmt.Sprintf("%s-%s-public-access", name, logical), &s3.BucketPublicAccessBlockArgs{
			Bucket:                bucket.ID(),
			BlockPublicAcls:       pulumi.Bool(true),
			BlockPublicPolicy:     pulumi.Bool(true),
			IgnorePublicAcls:      pulumi.Bool(true),
			RestrictPublicBuckets: pulumi.Bool(true),
		}, child...); err != nil {
			return nil, err
		}

		if _, err := s3.NewBucketServerSideEncryptionConfiguration(ctx, fmt.Sprintf("%s-%s-encryption", name, logical), &s3.BucketServerSideEncryptionConfigurationArgs{
			Bucket: bucket.ID(),
			Rules: s3.BucketServerSideEncryptionConfigurationRuleArray{
				&s3.BucketServerSideEncryptionConfigurationRuleArgs{
					ApplyServerSideEncryptionByDefault: &s3.BucketServerSideEncryptionConfigurationRuleApplyServerSideEncryptionByDefaultArgs{
						SseAlgorithm: pulumi.String("AES256"),
					},
				},
			},
		}, child...); err != nil {
			return nil, err
		}

		component.BucketNames[logical] = bucket.ID().ToStringOutput()
		component.BucketArns = append(component.BucketArns, bucket.Arn)
	}

	// Versioning is deliberately absent. It protects against an overwrite or a
	// delete of something irreplaceable, and nothing here is: sprue writes these
	// objects and can write them again. Enabling it costs a lifecycle rule to
	// stop noncurrent versions accumulating forever, and it stops a bucket being
	// deleted until every version has been purged one page at a time.

	// The delegator's two tables. It uses no Postgres at all, and creates
	// neither table itself, so both have to exist before it starts.
	allowList, err := dynamodb.NewTable(ctx, name+"-allow-list", &dynamodb.TableArgs{
		Name:        pulumi.String(fullName + "-delegator-allow-list"),
		BillingMode: pulumi.String("PAY_PER_REQUEST"),
		HashKey:     pulumi.String("did"),
		Attributes: dynamodb.TableAttributeArray{
			&dynamodb.TableAttributeArgs{
				Name: pulumi.String("did"),
				Type: pulumi.String("S"),
			},
		},
		PointInTimeRecovery: &dynamodb.TablePointInTimeRecoveryArgs{
			Enabled: pulumi.Bool(args.PointInTimeRecovery),
		},
		Tags: pulumi.StringMap{"Name": pulumi.String(fullName + "-delegator-allow-list")},
	}, child...)
	if err != nil {
		return nil, err
	}

	providerInfo, err := dynamodb.NewTable(ctx, name+"-provider-info", &dynamodb.TableArgs{
		Name:        pulumi.String(fullName + "-delegator-provider-info"),
		BillingMode: pulumi.String("PAY_PER_REQUEST"),
		HashKey:     pulumi.String("provider"),
		Attributes: dynamodb.TableAttributeArray{
			&dynamodb.TableAttributeArgs{
				Name: pulumi.String("provider"),
				Type: pulumi.String("S"),
			},
		},
		PointInTimeRecovery: &dynamodb.TablePointInTimeRecoveryArgs{
			Enabled: pulumi.Bool(args.PointInTimeRecovery),
		},
		Tags: pulumi.StringMap{"Name": pulumi.String(fullName + "-delegator-provider-info")},
	}, child...)
	if err != nil {
		return nil, err
	}

	component.AllowListTableName = allowList.Name
	component.ProviderInfoTableName = providerInfo.Name
	component.TableArns = pulumi.StringArray{allowList.Arn, providerInfo.Arn}

	if err := ctx.RegisterResourceOutputs(component, pulumi.Map{
		"allowListTableName":    component.AllowListTableName,
		"providerInfoTableName": component.ProviderInfoTableName,
	}); err != nil {
		return nil, err
	}

	return component, nil
}
