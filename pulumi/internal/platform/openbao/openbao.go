// Package openbao builds the central OpenBao.
//
// It serves hilt's tenant secrets, and under fil-one/RFC#21 it is also the root
// of trust for regional appliances: each appliance's local OpenBao seals its
// storage with seal "transit" against this instance, authenticating here at boot
// to unseal. That is why it has a public hostname rather than living only on the
// private namespace, and why its availability is load-bearing.
//
// Three departures from smelt's Vault, all forced by Fargate having no durable
// local disk and no operator at the console:
//
//	storage    Postgres on the shared RDS, not raft on a volume.
//	seal       KMS, so there is no unseal key, no 1Password item holding it,
//	           and no sidecar polling to apply it.
//	auth       hilt gets an AppRole scoped to its own mount, not the root token.
package openbao

import (
	"fmt"
	"strings"

	"github.com/pulumi/pulumi-aws/sdk/v7/go/aws/iam"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"

	"github.com/fil-forge/infra-central/pulumi/internal/ecsservice"
)

// configPath is where the entrypoint writes the generated config.
const configPath = "/tmp/forge/openbao.hcl"

// Args configures OpenBao.
type Args struct {
	Stage     string
	Region    string
	AccountID string

	// Image defaults to openbao/openbao:2.6.0. 2.6.x is the series
	// fil-one/RFC#21 benchmarked.
	Image string

	// Port defaults to 8200.
	Port int

	// MaxParallel is the number of Postgres connections OpenBao may open. Its own
	// default is 128, which is fine for a dedicated database and rude to one
	// shared with four application services.
	//
	// Budget against the instance's real max_connections (roughly
	// DBInstanceClassMemory/9531392, about 112 on a db.t4g.micro) alongside
	// sprue, hilt and swarf, which each default to max_conns = 10. RDS Proxy is
	// the escape hatch if the budget gets tight. Zero defaults to 16.
	MaxParallel int

	// Hostname is the public hostname. Regional appliances authenticate here at
	// boot to unseal, so this cannot be internal-only.
	Hostname string

	ClusterArn      pulumi.StringInput
	VpcID           pulumi.StringInput
	SubnetIDs       pulumi.StringArrayInput
	SecurityGroupID pulumi.StringInput

	KmsKeyID  pulumi.StringInput
	KmsKeyArn pulumi.StringInput

	// SSMPrefix is the parameter prefix for openbao, e.g.
	// /forge-central/dev/openbao.
	SSMPrefix string

	ListenerArn pulumi.StringInput
	// ListenerPriority defaults to 100.
	ListenerPriority int
	Route53ZoneID    pulumi.StringInput
	AlbDNSName       pulumi.StringInput
	AlbZoneID        pulumi.StringInput

	NamespaceID   pulumi.StringInput
	NamespaceName pulumi.StringInput

	EnableUI bool

	CPU    int
	Memory int
}

// OpenBao is the stage's OpenBao service.
type OpenBao struct {
	pulumi.ResourceState

	// InternalAddress is how hilt and the provision Lambda reach OpenBao, inside
	// the VPC and without TLS termination in the way.
	InternalAddress pulumi.StringOutput

	// PublicURL is where regional appliances authenticate at boot.
	PublicURL pulumi.StringOutput

	TaskRoleArn pulumi.StringOutput
}

// New creates the service.
func New(ctx *pulumi.Context, name string, args *Args, opts ...pulumi.ResourceOption) (*OpenBao, error) {
	if args.Stage == "" || args.Hostname == "" || args.SSMPrefix == "" {
		return nil, fmt.Errorf("openbao: stage, hostname and ssm prefix are all required")
	}
	if args.KmsKeyID == nil || args.KmsKeyArn == nil {
		return nil, fmt.Errorf("openbao: the seal key's id and arn are both required")
	}

	if args.Image == "" {
		args.Image = "openbao/openbao:2.6.0"
	}
	if args.Port == 0 {
		args.Port = 8200
	}
	if args.MaxParallel == 0 {
		args.MaxParallel = 16
	}
	if args.ListenerPriority == 0 {
		args.ListenerPriority = 100
	}
	if args.CPU == 0 {
		args.CPU = 512
	}
	if args.Memory == 0 {
		args.Memory = 1024
	}

	// Below 4 OpenBao serialises under load, above 64 it starves the application
	// services of connections.
	if args.MaxParallel < 4 || args.MaxParallel > 64 {
		return nil, fmt.Errorf("openbao: max parallel is %d; it should stay between 4 and 64", args.MaxParallel)
	}

	component := &OpenBao{}
	if err := ctx.RegisterComponentResource("forge:index:OpenBao", name, component, opts...); err != nil {
		return nil, err
	}

	child := []pulumi.ResourceOption{pulumi.Parent(component)}

	// Unsealing is a direct KMS operation, so unlike the parameter-decryption
	// grant this one carries no kms:ViaService condition. The key is created in the
	// same run, and passes straight through as an input.
	sealPolicy := iam.GetPolicyDocumentOutput(ctx, iam.GetPolicyDocumentOutputArgs{
		Statements: iam.GetPolicyDocumentStatementArray{
			iam.GetPolicyDocumentStatementArgs{
				Sid: pulumi.String("UnsealWithKMS"),
				Actions: pulumi.StringArray{
					pulumi.String("kms:Encrypt"),
					pulumi.String("kms:Decrypt"),
					pulumi.String("kms:DescribeKey"),
				},
				Resources: pulumi.StringArray{args.KmsKeyArn},
			},
		},
	}, pulumi.InvokeOption(pulumi.Parent(component))).Json()

	service, err := ecsservice.New(ctx, name+"-service", &ecsservice.Args{
		Stage:     args.Stage,
		Service:   "openbao",
		Region:    args.Region,
		AccountID: args.AccountID,

		Image:         pulumi.String(args.Image),
		ContainerPort: args.Port,

		ClusterArn:      args.ClusterArn,
		VpcID:           args.VpcID,
		SubnetIDs:       args.SubnetIDs,
		SecurityGroupID: args.SecurityGroupID,

		Secrets: pulumi.StringMap{
			"OPENBAO_POSTGRES_DSN": pulumi.String(args.SSMPrefix + "/postgres-dsn"),
		},

		// TLS terminates at the ALB, so OpenBao's own listener is plaintext
		// inside the VPC. Both hilt and the provision Lambda reach it that way.
		Environment: pulumi.StringMap{
			"BAO_ADDR": pulumi.String(fmt.Sprintf("http://127.0.0.1:%d", args.Port)),
		},

		ShellCommand: entrypoint(args),

		// uninitcode=200 matters: a fresh OpenBao answers /sys/health with 501
		// until it is initialised, and the provision Lambda cannot initialise a
		// task that ECS has already killed for failing its health check. A sealed
		// instance still reports 503, because with a KMS seal that is a real
		// fault.
		HealthCheckPath:    "/v1/sys/health?standbyok=true&uninitcode=200",
		HealthCheckCommand: fmt.Sprintf("wget -q -O - http://127.0.0.1:%d/v1/sys/health?standbyok=true\\&uninitcode=200 > /dev/null", args.Port),

		Hostname:         pulumi.String(args.Hostname),
		ListenerArn:      args.ListenerArn,
		ListenerPriority: args.ListenerPriority,
		Route53ZoneID:    args.Route53ZoneID,
		AlbDNSName:       args.AlbDNSName,
		AlbZoneID:        args.AlbZoneID,

		RegisterInternal: true,
		NamespaceID:      args.NamespaceID,
		NamespaceName:    args.NamespaceName,

		TaskPolicies: map[string]pulumi.StringInput{"service-permissions": sealPolicy},

		// Raising this needs ha_enabled in the storage stanza. Until then a
		// second task would be a second writer, not a standby.
		DesiredCount: 1,

		CPU:    args.CPU,
		Memory: args.Memory,
	}, child...)
	if err != nil {
		return nil, err
	}

	component.InternalAddress = service.InternalHostname.ApplyT(func(hostname string) string {
		return fmt.Sprintf("http://%s:%d", hostname, args.Port)
	}).(pulumi.StringOutput)
	component.PublicURL = service.PublicURL
	component.TaskRoleArn = service.TaskRoleArn

	if err := ctx.RegisterResourceOutputs(component, pulumi.Map{
		"internalAddress": component.InternalAddress,
		"publicUrl":       component.PublicURL,
	}); err != nil {
		return nil, err
	}

	return component, nil
}

// entrypoint writes the config and then starts the server.
//
// The config is assembled here rather than through a secret file because it is a
// template around a secret, not a secret in its own right. The heredoc delimiter
// is deliberately unquoted so the shell substitutes the DSN; the config contains
// no other shell metacharacters.
func entrypoint(args *Args) pulumi.StringOutput {
	return args.KmsKeyID.ToStringOutput().ApplyT(func(keyID string) string {
		// Written by the entrypoint rather than baked into the image because the
		// connection URL carries a password and OpenBao's HCL does not
		// interpolate environment variables. $OPENBAO_POSTGRES_DSN is expanded by
		// the shell at startup, which is why it survives this far unquoted.
		config := fmt.Sprintf(`storage "postgresql" {
  connection_url = "$OPENBAO_POSTGRES_DSN"
  max_parallel   = %d
  ha_enabled     = "false"
}

listener "tcp" {
  address     = "0.0.0.0:%d"
  tls_disable = 1
}

seal "awskms" {
  region     = "%s"
  kms_key_id = "%s"
}

api_addr      = "https://%s"
disable_mlock = true
ui            = %t
`, args.MaxParallel, args.Port, args.Region, keyID, args.Hostname, args.EnableUI)

		return strings.Join([]string{
			"umask 077",
			"mkdir -p " + directory(configPath),
			"cat > " + configPath + " <<EOF",
			config,
			"EOF",
			"bao server -config=" + configPath,
		}, "\n")
	}).(pulumi.StringOutput)
}

// directory is path.Dir for the one path this package writes, kept local so the
// config's location is stated once.
func directory(path string) string {
	if index := strings.LastIndex(path, "/"); index > 0 {
		return path[:index]
	}

	return "/"
}
