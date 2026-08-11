// Package provision builds the provision Lambda.
//
// This is where every secret in the stage is born. The program invokes the
// function and receives DIDs, wallet addresses and database names; the private
// keys behind them are written straight to SSM and never cross this boundary.
//
// The invocations themselves live in the caller rather than here, because the two
// phases sit on opposite sides of OpenBao: seed must finish before OpenBao starts
// (it creates OpenBao's database), and vault cannot run until OpenBao is serving.
package provision

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"

	"github.com/pulumi/pulumi-aws/sdk/v7/go/aws/cloudwatch"
	"github.com/pulumi/pulumi-aws/sdk/v7/go/aws/iam"
	"github.com/pulumi/pulumi-aws/sdk/v7/go/aws/lambda"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"

	"github.com/fil-forge/infra-central/pulumi/internal/chain"
	"github.com/fil-forge/infra-central/pulumi/internal/iamdoc"
)

// digest matches the manifest digest `make publish` writes.
var digest = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)

// Args configures the function.
type Args struct {
	Stage     string
	Region    string
	AccountID string

	// ImageRepositoryURL is the ECR repository URL for the provision image, from
	// the bootstrap stack for this stage's region.
	ImageRepositoryURL string

	// ImageDigest is the manifest digest written by `make publish`, e.g.
	// sha256:abc... Dev reads it from a gitignored config file; prod commits it.
	ImageDigest string

	// HostnameSuffix builds the did:web identities the startup proofs are
	// addressed to, e.g. dev.fil.one.
	HostnameSuffix string

	Chain chain.Config

	// SubnetIDs are the private subnets. The function needs a route to RDS and to
	// OpenBao.
	SubnetIDs       pulumi.StringArrayInput
	SecurityGroupID pulumi.StringInput

	DBHost                  pulumi.StringInput
	DBPort                  pulumi.IntInput
	DBMasterSecretArn       pulumi.StringInput
	DBMasterSecretKmsKeyArn pulumi.StringInput

	// OpenBaoAddress is the internal OpenBao URL. Only the vault phase uses it.
	OpenBaoAddress pulumi.StringInput

	// PrivateCIDRs are the VPC private subnets, used to bound hilt's AppRole
	// token.
	PrivateCIDRs pulumi.StringArrayInput

	// LogRetentionDays defaults to 30.
	LogRetentionDays int
}

// Provision is the stage's provision Lambda.
type Provision struct {
	pulumi.ResourceState

	FunctionName pulumi.StringOutput
	FunctionArn  pulumi.StringOutput
	RoleArn      pulumi.StringOutput
}

// New creates the function, its log group and its role.
func New(ctx *pulumi.Context, name string, args *Args, opts ...pulumi.ResourceOption) (*Provision, error) {
	if args.Stage == "" || args.Region == "" || args.AccountID == "" {
		return nil, fmt.Errorf("provision: stage, region and account id are all required")
	}
	if args.ImageRepositoryURL == "" {
		return nil, fmt.Errorf("provision: image repository url is required")
	}

	// A digest, not a tag. The image can then never move underneath a deploy, and
	// an identical rebuild produces no diff here at all.
	if !digest.MatchString(args.ImageDigest) {
		return nil, fmt.Errorf("provision: image digest %q is not a sha256 manifest digest; run `make publish`, which writes one for the dev stage and prints the line to commit for prod", args.ImageDigest)
	}

	if args.LogRetentionDays == 0 {
		args.LogRetentionDays = 30
	}

	component := &Provision{}
	if err := ctx.RegisterComponentResource("forge:index:Provision", name, component, opts...); err != nil {
		return nil, err
	}

	child := []pulumi.ResourceOption{pulumi.Parent(component)}
	fullName := fmt.Sprintf("fc-%s-provision", args.Stage)

	role, err := newRole(ctx, name, fullName, args, child)
	if err != nil {
		return nil, err
	}

	function, err := lambda.NewFunction(ctx, name+"-function", &lambda.FunctionArgs{
		Name:        pulumi.String(fullName),
		Role:        role.Arn,
		PackageType: pulumi.String("Image"),

		ImageUri: pulumi.String(args.ImageRepositoryURL + "@" + args.ImageDigest),

		Architectures: pulumi.StringArray{pulumi.String("arm64")},

		// Generous because the first run of a stage waits for the OpenBao task to
		// finish a cold start before it can configure it.
		Timeout:    pulumi.Int(600),
		MemorySize: pulumi.Int(512),

		VpcConfig: &lambda.FunctionVpcConfigArgs{
			SubnetIds:        args.SubnetIDs,
			SecurityGroupIds: pulumi.StringArray{args.SecurityGroupID.ToStringOutput()},
		},

		Environment: &lambda.FunctionEnvironmentArgs{
			Variables: environment(args),
		},

		Tags: pulumi.StringMap{"Name": pulumi.String(fullName)},
	}, child...)
	if err != nil {
		return nil, err
	}

	if _, err := cloudwatch.NewLogGroup(ctx, name+"-logs", &cloudwatch.LogGroupArgs{
		Name:            pulumi.String("/aws/lambda/" + fullName),
		RetentionInDays: pulumi.Int(args.LogRetentionDays),
	}, child...); err != nil {
		return nil, err
	}

	component.FunctionName = function.Name
	component.FunctionArn = function.Arn
	component.RoleArn = role.Arn

	if err := ctx.RegisterResourceOutputs(component, pulumi.Map{
		"functionName": component.FunctionName,
		"functionArn":  component.FunctionArn,
		"roleArn":      component.RoleArn,
	}); err != nil {
		return nil, err
	}

	return component, nil
}

// environment is the function's configuration. Every value here is public: the
// secrets the function handles are the ones it mints, and those go to SSM.
func environment(args *Args) pulumi.StringMapInput {
	return pulumi.StringMap{
		"FORGE_STAGE":                pulumi.String(args.Stage),
		"FORGE_HOSTNAME_SUFFIX":      pulumi.String(args.HostnameSuffix),
		"FORGE_DB_HOST":              args.DBHost,
		"FORGE_DB_PORT":              args.DBPort.ToIntOutput().ApplyT(strconv.Itoa).(pulumi.StringOutput),
		"FORGE_DB_MASTER_SECRET_ARN": args.DBMasterSecretArn,
		"FORGE_OPENBAO_ADDR":         args.OpenBaoAddress,
		"FORGE_PRIVATE_CIDRS": args.PrivateCIDRs.ToStringArrayOutput().ApplyT(func(cidrs []string) string {
			return strings.Join(cidrs, ",")
		}).(pulumi.StringOutput),

		// Used only by the fund phase, which no deployment invokes.
		"FORGE_CHAIN_RPC_URL":        pulumi.String(args.Chain.RPCURL),
		"FORGE_CHAIN_ID":             pulumi.String(strconv.Itoa(args.Chain.ChainID)),
		"FORGE_USDFC_ADDRESS":        pulumi.String(args.Chain.Contracts.USDFCToken),
		"FORGE_FILECOIN_PAY_ADDRESS": pulumi.String(args.Chain.Contracts.FilecoinPay),
		"FORGE_FWSS_ADDRESS":         pulumi.String(args.Chain.Contracts.FWSS),
	}
}

// newRole builds the provision Lambda's role. This is the one principal that can
// read across every service prefix, because it is the one thing that writes them
// all.
func newRole(ctx *pulumi.Context, name, fullName string, args *Args, child []pulumi.ResourceOption) (*iam.Role, error) {
	role, err := iam.NewRole(ctx, name+"-role", &iam.RoleArgs{
		Name:             pulumi.String(fullName),
		AssumeRolePolicy: pulumi.String(iamdoc.AssumeRole("lambda.amazonaws.com")),
	}, child...)
	if err != nil {
		return nil, err
	}

	if _, err := iam.NewRolePolicyAttachment(ctx, name+"-vpc-access", &iam.RolePolicyAttachmentArgs{
		Role:      role.Name,
		PolicyArn: pulumi.String("arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"),
	}, child...); err != nil {
		return nil, err
	}

	// The two RDS statements name the master secret and its key, which the
	// database module creates in the same run, so the document is assembled
	// inside an apply over those two ARNs.
	policy := pulumi.All(args.DBMasterSecretArn.ToStringOutput(), args.DBMasterSecretKmsKeyArn.ToStringOutput()).
		ApplyT(func(resolved []interface{}) (string, error) {
			secretArn, _ := resolved[0].(string)
			keyArn, _ := resolved[1].(string)

			return iamdoc.New(
				iamdoc.Statement{
					Sid: "ManageStageParameters",
					Actions: []string{
						"ssm:PutParameter",
						"ssm:GetParameter",
						"ssm:GetParameters",
						"ssm:GetParametersByPath",
						"ssm:DescribeParameters",
					},
					Resources: []string{
						fmt.Sprintf("arn:aws:ssm:%s:%s:parameter/forge-central/%s/*", args.Region, args.AccountID, args.Stage),
					},
				},

				// SecureStrings take the account's AWS-managed SSM key, which no
				// stage owns and no destroy can remove, so the parameters stay
				// readable after the stage that minted them is gone. The key has
				// no stable ARN to name here without a lookup that fails in an
				// account which has never written one, so the grant is bounded by
				// the service that may use it instead.
				iamdoc.Statement{
					Sid:       "EncryptAndDecryptParameters",
					Actions:   []string{"kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"},
					Resources: []string{"*"},
					Condition: map[string]iamdoc.Condition{
						"StringEquals": {"kms:ViaService": []string{"ssm." + args.Region + ".amazonaws.com"}},
					},
				},

				// The RDS master credentials, which no deployment ever sees
				// because manage_master_user_password keeps them out of state.
				iamdoc.Statement{
					Sid:       "ReadRDSMasterSecret",
					Actions:   []string{"secretsmanager:GetSecretValue"},
					Resources: []string{secretArn},
				},
				iamdoc.Statement{
					Sid:       "DecryptRDSMasterSecret",
					Actions:   []string{"kms:Decrypt"},
					Resources: []string{keyArn},
					Condition: map[string]iamdoc.Condition{
						"StringEquals": {"kms:ViaService": []string{"secretsmanager." + args.Region + ".amazonaws.com"}},
					},
				},
			).JSON()
		}).(pulumi.StringOutput)

	if _, err := iam.NewRolePolicy(ctx, name+"-policy", &iam.RolePolicyArgs{
		Name:   pulumi.String("provision"),
		Role:   role.ID(),
		Policy: policy,
	}, child...); err != nil {
		return nil, err
	}

	return role, nil
}
