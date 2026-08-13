// Package ecsservice builds one Forge service: task definition, service, ALB
// routing, DNS and IAM.
//
// Two things here are less obvious than they look.
//
// The entrypoint wrapper exists because ECS injects secrets as environment
// variables, while hilt and swarf accept their identity key only as a file path
// and the delegator's UCAN proofs are file-only in current code. Rather than
// mounting a volume or shipping a sidecar, the container writes what it needs to
// a tmpfs at startup and then execs the real process. A binary secret arrives
// base64-encoded, because an environment variable cannot carry a NUL byte.
//
// The IAM scoping is per service, not per stage. Each execution role can read
// only /forge-central/<stage>/<service>/*, so a compromised sprue task cannot
// read hilt's AppRole secret_id or the delegator's transactor key.
package ecsservice

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"

	"github.com/pulumi/pulumi-aws/sdk/v7/go/aws/cloudwatch"
	"github.com/pulumi/pulumi-aws/sdk/v7/go/aws/ecs"
	"github.com/pulumi/pulumi-aws/sdk/v7/go/aws/iam"
	"github.com/pulumi/pulumi-aws/sdk/v7/go/aws/lb"
	"github.com/pulumi/pulumi-aws/sdk/v7/go/aws/route53"
	"github.com/pulumi/pulumi-aws/sdk/v7/go/aws/servicediscovery"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
)

// assumeRole lets ECS assume both of a service's roles.
//
// A literal rather than an iam.GetPolicyDocument call: it is three fixed fields,
// and generating it would be a provider round trip per role — twelve across the six
// services — to produce exactly these bytes.
const assumeRole = `{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "sts:AssumeRole",
    "Principal": {"Service": "ecs-tasks.amazonaws.com"}
  }]
}`

// SecretDir is where the entrypoint wrapper writes file-borne secrets. Callers
// point their *_KEY_FILE settings at paths under it.
//
// Every file-borne secret lands in one directory, so the path is a single known
// one rather than something derived from the caller's filenames.
//
// Under /tmp because that is the only directory an image is relied on to leave
// world-writable. A Fargate ephemeral volume mounts root-owned with no uid or
// gid option, so mounting one here would lock out every container that does not
// run as root, and the delegator and the signing service both end their images
// with USER nobody. The container filesystem carries the same AES-256
// encryption and dies with the task either way, so the volume bought nothing
// the write into /tmp does not already have.
const SecretDir = "/tmp/forge"

// DefaultNamespace is the private DNS namespace services register in.
const DefaultNamespace = "forge-central.internal"

// Args configures one service.
//
// Where Terraform had a nullable variable, the field is a pulumi input that may
// be left nil: Hostname nil gives the service no ALB route and no public DNS, as
// with plc. Nullness is decided while the program builds the graph, exactly as
// Terraform decided it while planning, so the conditionals below need no apply.
type Args struct {
	// Stage is the deployment stage, and Service the service name. Both are
	// plain strings because they name resources.
	//
	// Service is also the SSM parameter prefix this task can read, so it must
	// match what the provision Lambda wrote.
	Stage   string
	Service string

	// Region and AccountID come from the provider rather than the caller's
	// configuration, resolved once per program by aws.GetRegion and
	// aws.GetCallerIdentity.
	Region    string
	AccountID string

	// Image is the full image reference. Prefer a digest in prod so a deploy
	// names exactly one artifact.
	Image         pulumi.StringInput
	ContainerPort int

	ClusterArn      pulumi.StringInput
	VpcID           pulumi.StringInput
	SubnetIDs       pulumi.StringArrayInput
	SecurityGroupID pulumi.StringInput

	// Environment holds plain environment variables. Never put a secret here:
	// task definitions are readable by anyone with ecs:DescribeTaskDefinition.
	Environment pulumi.StringMap

	// Secrets maps an environment variable name to an SSM parameter ARN. ECS
	// resolves these at task start.
	Secrets pulumi.StringMap

	// SecretFiles maps an environment variable name to a filename, for secrets a
	// service can only read from a file. The entrypoint wrapper writes each one
	// into SecretDir at 0400 before exec'ing the process.
	//
	// Needed because hilt and swarf accept their identity key only as a path,
	// and the delegator's UCAN proofs are file-only in current code. Every key
	// here must also appear in Secrets, and setting this requires ShellCommand.
	//
	// Use SecretFilesBase64 for a value whose bytes are not text.
	SecretFiles map[string]string

	// SecretFilesBase64 is as SecretFiles, for a parameter stored
	// base64-encoded: the wrapper decodes it on the way to the file.
	//
	// This is how a binary secret travels at all. ECS injects every secret as an
	// environment variable, and an environment variable cannot hold a NUL byte:
	// runc refuses to create the container and reports only the variable's name.
	// The delegator's two UCAN proofs are bare DAG-CBOR, so they take this path.
	SecretFilesBase64 map[string]string

	// ShellCommand is the command to exec, as a shell string. Required when
	// either secret-files map is set, because the wrapper replaces the image's
	// entrypoint. Nil uses the image's own entrypoint and command.
	//
	// An input rather than a string because OpenBao's command carries its
	// generated config, which names the KMS key created in the same run.
	ShellCommand pulumi.StringInput

	// HealthCheckCommand is the container-level health check. Base images
	// differ: the debian-based services have curl, the alpine ones have wget.
	HealthCheckCommand string

	// HealthCheckPath is the ALB health check path. /health for sprue, hilt and
	// swarf; /healthcheck for the delegator and signing service; /_health for
	// plc. Empty defaults to /health.
	HealthCheckPath string

	// HealthCheckStartPeriod is seconds before health checks count. The
	// Postgres-backed services run goose migrations during this window. Zero
	// defaults to 90.
	HealthCheckStartPeriod int

	// Hostname is the public hostname. Nil gives the service no ALB route and no
	// public DNS, as with plc, and the four routing inputs below are then unused.
	Hostname         pulumi.StringInput
	ListenerArn      pulumi.StringInput
	ListenerPriority int
	Route53ZoneID    pulumi.StringInput
	AlbDNSName       pulumi.StringInput
	AlbZoneID        pulumi.StringInput

	// RegisterInternal registers the service in the private namespace, for
	// callers inside the VPC.
	RegisterInternal bool
	NamespaceID      pulumi.StringInput
	NamespaceName    pulumi.StringInput

	// TaskPolicies holds extra permissions for the running process, keyed by
	// policy name. Only sprue, the delegator and OpenBao need any.
	//
	// Keyed rather than one nullable string because the name is what the policy
	// resource is addressed by. A policy body usually names resources created in
	// the same run, which is why the values are inputs rather than strings.
	TaskPolicies map[string]pulumi.StringInput

	// DesiredCount above 1 makes concurrent starts race on the goose migration
	// lock. Set the service's *_SKIP_MIGRATIONS before raising it. Zero
	// defaults to 1.
	DesiredCount int

	CPU    int
	Memory int

	// CPUArchitecture defaults to ARM64: all six service images publish
	// linux/arm64 as well as amd64, and Graviton Fargate is cheaper.
	CPUArchitecture string

	LogRetentionDays int
}

// Service is one deployed Forge service.
type Service struct {
	pulumi.ResourceState

	TaskRoleArn      pulumi.StringOutput
	ExecutionRoleArn pulumi.StringOutput
	LogGroupName     pulumi.StringOutput

	// InternalHostname is the private DNS name, for callers inside the VPC. Nil
	// when the service is not registered internally.
	InternalHostname pulumi.StringOutput

	// PublicURL is nil when the service has no public hostname, as with plc.
	PublicURL pulumi.StringOutput

	// Registered reports whether the service took a private DNS record, and
	// Public whether it took an ALB route, so a caller can tell an absent
	// output from an empty one.
	Registered bool
	Public     bool
}

// defaults fills in what Terraform expressed as variable defaults and validates
// what it expressed as variable validation blocks.
func (a *Args) defaults() error {
	if a.Stage == "" || a.Service == "" {
		return fmt.Errorf("ecsservice: stage and service are both required, got %q and %q", a.Stage, a.Service)
	}

	if a.Region == "" || a.AccountID == "" {
		return fmt.Errorf("ecsservice %s: region and account id are both required", a.Service)
	}

	if a.ContainerPort == 0 {
		return fmt.Errorf("ecsservice %s: container port is required", a.Service)
	}

	if a.HealthCheckCommand == "" {
		return fmt.Errorf("ecsservice %s: health check command is required", a.Service)
	}

	// Writing a secret to a file replaces the image entrypoint with a wrapper,
	// so ShellCommand must say what to exec afterwards.
	if len(a.SecretFiles)+len(a.SecretFilesBase64) > 0 && a.ShellCommand == nil {
		return fmt.Errorf("ecsservice %s: secret files need a shell command to exec after the wrapper writes them", a.Service)
	}

	// Every secret-file key must also be a Secrets key: the wrapper writes an
	// environment variable to a file, so ECS has to inject it first. A missing
	// entry writes an empty file and the service fails at startup with an
	// unhelpful parse error.
	for _, files := range []map[string]string{a.SecretFiles, a.SecretFilesBase64} {
		for _, envVar := range sortedKeys(files) {
			if _, ok := a.Secrets[envVar]; !ok {
				return fmt.Errorf("ecsservice %s: %s is written to a file but is not in secrets, so ECS would never inject it", a.Service, envVar)
			}
		}
	}

	if a.Hostname != nil && (a.ListenerArn == nil || a.ListenerPriority == 0 || a.Route53ZoneID == nil || a.AlbDNSName == nil || a.AlbZoneID == nil) {
		return fmt.Errorf("ecsservice %s: a public hostname needs a listener, a priority, a zone and the load balancer's dns name and zone", a.Service)
	}

	if a.RegisterInternal && a.NamespaceID == nil {
		return fmt.Errorf("ecsservice %s: registering internally needs a namespace id", a.Service)
	}

	if a.HealthCheckPath == "" {
		a.HealthCheckPath = "/health"
	}
	if a.HealthCheckStartPeriod == 0 {
		a.HealthCheckStartPeriod = 90
	}
	if a.NamespaceName == nil {
		a.NamespaceName = pulumi.String(DefaultNamespace)
	}
	if a.DesiredCount == 0 {
		a.DesiredCount = 1
	}
	if a.CPU == 0 {
		a.CPU = 512
	}
	if a.Memory == 0 {
		a.Memory = 1024
	}
	if a.CPUArchitecture == "" {
		a.CPUArchitecture = "ARM64"
	}
	if a.LogRetentionDays == 0 {
		a.LogRetentionDays = 30
	}

	return nil
}

// New builds the service.
func New(ctx *pulumi.Context, name string, args *Args, opts ...pulumi.ResourceOption) (*Service, error) {
	if err := args.defaults(); err != nil {
		return nil, err
	}

	component := &Service{Registered: args.RegisterInternal, Public: args.Hostname != nil}
	if err := ctx.RegisterComponentResource("forge:index:EcsService", name, component, opts...); err != nil {
		return nil, err
	}

	// Children inherit the provider from the component, so the account guard and
	// default tags configured on it apply without being threaded through. Invokes
	// resolve their provider from the parent the same way.
	child := []pulumi.ResourceOption{pulumi.Parent(component)}
	invoke := pulumi.InvokeOption(pulumi.Parent(component))

	fullName := fmt.Sprintf("fc-%s-%s", args.Stage, args.Service)
	ssmPrefixArn := fmt.Sprintf("arn:aws:ssm:%s:%s:parameter/forge-central/%s/%s/*", args.Region, args.AccountID, args.Stage, args.Service)

	logGroup, err := cloudwatch.NewLogGroup(ctx, name+"-logs", &cloudwatch.LogGroupArgs{
		Name:            pulumi.String(fmt.Sprintf("/forge-central/%s/%s", args.Stage, args.Service)),
		RetentionInDays: pulumi.Int(args.LogRetentionDays),
	}, child...)
	if err != nil {
		return nil, err
	}

	roles, err := newRoles(ctx, name, fullName, ssmPrefixArn, args, child, invoke)
	if err != nil {
		return nil, err
	}

	taskDefinition, err := ecs.NewTaskDefinition(ctx, name+"-task", &ecs.TaskDefinitionArgs{
		Family:                  pulumi.String(fullName),
		RequiresCompatibilities: pulumi.StringArray{pulumi.String("FARGATE")},
		NetworkMode:             pulumi.String("awsvpc"),
		Cpu:                     pulumi.String(fmt.Sprint(args.CPU)),
		Memory:                  pulumi.String(fmt.Sprint(args.Memory)),
		ExecutionRoleArn:        roles.execution.Arn,
		TaskRoleArn:             roles.task.Arn,
		RuntimePlatform: &ecs.TaskDefinitionRuntimePlatformArgs{
			OperatingSystemFamily: pulumi.String("LINUX"),
			CpuArchitecture:       pulumi.String(args.CPUArchitecture),
		},
		ContainerDefinitions: containerDefinitions(args, logGroup.Name),
	}, child...)
	if err != nil {
		return nil, err
	}

	routing, err := newRouting(ctx, name, fullName, args, child)
	if err != nil {
		return nil, err
	}

	serviceArgs := &ecs.ServiceArgs{
		Name:           pulumi.String(fullName),
		Cluster:        args.ClusterArn,
		TaskDefinition: taskDefinition.Arn,
		DesiredCount:   pulumi.Int(args.DesiredCount),
		LaunchType:     pulumi.String("FARGATE"),

		// Migrations run in-process via goose for sprue, hilt, swarf and plc,
		// and concurrent starts race on the goose advisory lock. At a desired
		// count of 1 that cannot happen; above it, set the service's
		// *_SKIP_MIGRATIONS and run them deliberately.
		DeploymentMinimumHealthyPercent: pulumi.Int(minimumHealthyPercent(args.DesiredCount)),
		DeploymentMaximumPercent:        pulumi.Int(200),

		NetworkConfiguration: &ecs.ServiceNetworkConfigurationArgs{
			Subnets:        args.SubnetIDs,
			SecurityGroups: pulumi.StringArray{args.SecurityGroupID.ToStringOutput()},
			AssignPublicIp: pulumi.Bool(false),
		},
	}

	if routing.targetGroup != nil {
		serviceArgs.LoadBalancers = ecs.ServiceLoadBalancerArray{
			&ecs.ServiceLoadBalancerArgs{
				TargetGroupArn: routing.targetGroup.Arn,
				ContainerName:  pulumi.String(args.Service),
				ContainerPort:  pulumi.Int(args.ContainerPort),
			},
		}

		// Gives the container time to start before the ALB starts counting
		// failures, which the Postgres-backed services need for their
		// migrations.
		serviceArgs.HealthCheckGracePeriodSeconds = pulumi.Int(args.HealthCheckStartPeriod)
	}

	if routing.discovery != nil {
		serviceArgs.ServiceRegistries = &ecs.ServiceServiceRegistriesArgs{
			RegistryArn: routing.discovery.Arn,
		}
	}

	// The listener rule has to exist before the service registers targets
	// behind it, which Terraform said with depends_on.
	serviceOpts := child
	if routing.listenerRule != nil {
		serviceOpts = append(serviceOpts, pulumi.DependsOn([]pulumi.Resource{routing.listenerRule}))
	}

	if _, err := ecs.NewService(ctx, name+"-service", serviceArgs, serviceOpts...); err != nil {
		return nil, err
	}

	component.TaskRoleArn = roles.task.Arn
	component.ExecutionRoleArn = roles.execution.Arn
	component.LogGroupName = logGroup.Name

	if args.RegisterInternal {
		component.InternalHostname = args.NamespaceName.ToStringOutput().ApplyT(func(namespace string) string {
			return args.Service + "." + namespace
		}).(pulumi.StringOutput)
	}

	if args.Hostname != nil {
		component.PublicURL = args.Hostname.ToStringOutput().ApplyT(func(hostname string) string {
			return "https://" + hostname
		}).(pulumi.StringOutput)
	}

	if err := ctx.RegisterResourceOutputs(component, pulumi.Map{
		"taskRoleArn":      component.TaskRoleArn,
		"executionRoleArn": component.ExecutionRoleArn,
		"logGroupName":     component.LogGroupName,
	}); err != nil {
		return nil, err
	}

	return component, nil
}

// minimumHealthyPercent keeps a single-task service replaceable: ECS cannot
// bring a second task up alongside the first when the floor is 100 and the
// ceiling is 200 on a count of one.
func minimumHealthyPercent(desiredCount int) int {
	if desiredCount > 1 {
		return 100
	}

	return 0
}

// --- container definitions ------------------------------------------------

// container is one ECS container definition. Rendering it from a struct rather
// than a map keeps the field order fixed, so an unchanged configuration produces
// a byte-identical definition and no task definition revision.
type container struct {
	Name         string           `json:"name"`
	Image        string           `json:"image"`
	Essential    bool             `json:"essential"`
	EntryPoint   []string         `json:"entryPoint,omitempty"`
	Command      []string         `json:"command,omitempty"`
	PortMappings []portMapping    `json:"portMappings"`
	Environment  []keyValue       `json:"environment"`
	Secrets      []secretRef      `json:"secrets"`
	LogConfig    logConfiguration `json:"logConfiguration"`
	HealthCheck  healthCheck      `json:"healthCheck"`
}

type portMapping struct {
	ContainerPort int    `json:"containerPort"`
	Protocol      string `json:"protocol"`
}

type keyValue struct {
	Name  string `json:"name"`
	Value string `json:"value"`
}

type secretRef struct {
	Name      string `json:"name"`
	ValueFrom string `json:"valueFrom"`
}

type logConfiguration struct {
	LogDriver string            `json:"logDriver"`
	Options   map[string]string `json:"options"`
}

// healthCheck is the container-level check. ECS restarts an unhealthy container
// without waiting for the ALB to drain it, which matters most for the services
// with no ALB route.
type healthCheck struct {
	Command     []string `json:"command"`
	Interval    int      `json:"interval"`
	Timeout     int      `json:"timeout"`
	Retries     int      `json:"retries"`
	StartPeriod int      `json:"startPeriod"`
}

// containerDefinitions renders the single-element definition array ECS expects.
//
// Everything that can be an output — the image reference, every environment
// value, every parameter ARN, the log group's name — is resolved together, so
// the JSON is produced once with no partially-known fields.
func containerDefinitions(args *Args, logGroupName pulumi.StringOutput) pulumi.StringOutput {
	// Nil means the image's own entrypoint stands, which reads the same as an
	// empty command once resolved.
	shellCommand := args.ShellCommand
	if shellCommand == nil {
		shellCommand = pulumi.String("")
	}

	return pulumi.All(
		args.Image.ToStringOutput(),
		args.Environment.ToStringMapOutput(),
		args.Secrets.ToStringMapOutput(),
		logGroupName,
		shellCommand.ToStringOutput(),
	).ApplyT(func(resolved []interface{}) (string, error) {
		image, _ := resolved[0].(string)
		environment, _ := resolved[1].(map[string]string)
		secrets, _ := resolved[2].(map[string]string)
		logGroup, _ := resolved[3].(string)
		shell, _ := resolved[4].(string)

		definition := container{
			Name:      args.Service,
			Image:     image,
			Essential: true,
			PortMappings: []portMapping{{
				ContainerPort: args.ContainerPort,
				Protocol:      "tcp",
			}},
			Environment: []keyValue{},
			Secrets:     []secretRef{},
			LogConfig: logConfiguration{
				LogDriver: "awslogs",
				Options: map[string]string{
					"awslogs-group":         logGroup,
					"awslogs-region":        args.Region,
					"awslogs-stream-prefix": args.Service,
				},
			},
			HealthCheck: healthCheck{
				Command:     []string{"CMD-SHELL", args.HealthCheckCommand + " || exit 1"},
				Interval:    30,
				Timeout:     5,
				Retries:     3,
				StartPeriod: args.HealthCheckStartPeriod,
			},
		}

		// Sorted, because Go map order is random and an unordered list here
		// would rewrite the task definition on every up. Terraform's maps were
		// sorted for it.
		for _, key := range sortedKeys(environment) {
			definition.Environment = append(definition.Environment, keyValue{Name: key, Value: environment[key]})
		}

		for _, key := range sortedKeys(secrets) {
			definition.Secrets = append(definition.Secrets, secretRef{Name: key, ValueFrom: secrets[key]})
		}

		if command := wrappedCommand(args, shell); command != "" {
			definition.EntryPoint = []string{"/bin/sh", "-c"}
			definition.Command = []string{command}
		}

		encoded, err := json.Marshal([]container{definition})
		if err != nil {
			return "", fmt.Errorf("marshal container definition for %s: %w", args.Service, err)
		}

		return string(encoded), nil
	}).(pulumi.StringOutput)
}

// wrappedCommand returns the shell command the container runs, with the
// secret-writing prelude in front of it. Empty means the image's own entrypoint
// and command are left alone.
func wrappedCommand(args *Args, shellCommand string) string {
	if shellCommand == "" {
		return ""
	}

	writes := fileWrites(args)
	if len(writes) == 0 {
		return shellCommand
	}

	prelude := append([]string{"umask 077 && mkdir -p " + SecretDir}, writes...)

	return strings.Join(prelude, " && ") + " && exec " + shellCommand
}

// fileWrites builds the shell commands that copy injected secrets to files.
//
// The $NAME references are expanded by the container's shell at startup, not
// here: printf's format string is a literal %s and the value is the environment
// variable ECS injected.
func fileWrites(args *Args) []string {
	var writes []string

	for _, envVar := range sortedKeys(args.SecretFiles) {
		path := SecretDir + "/" + args.SecretFiles[envVar]
		writes = append(writes, fmt.Sprintf("printf '%%s' \"$%s\" > %s && chmod 400 %s", envVar, path, path))
	}

	for _, envVar := range sortedKeys(args.SecretFilesBase64) {
		path := SecretDir + "/" + args.SecretFilesBase64[envVar]
		writes = append(writes, fmt.Sprintf("printf '%%s' \"$%s\" | base64 -d > %s && chmod 400 %s", envVar, path, path))
	}

	return writes
}

func sortedKeys[V any](values map[string]V) []string {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)

	return keys
}

// --- IAM ------------------------------------------------------------------

// Two roles per service, both scoped to that service alone.
//
// The execution role pulls the image and reads secrets; the task role is what
// the running process uses. Keeping them separate means the application's own
// credentials cannot read the parameters it was started with.
type serviceRoles struct {
	execution *iam.Role
	task      *iam.Role
}

func newRoles(ctx *pulumi.Context, name, fullName, ssmPrefixArn string, args *Args, child []pulumi.ResourceOption, invoke pulumi.InvokeOption) (*serviceRoles, error) {
	execution, err := iam.NewRole(ctx, name+"-execution-role", &iam.RoleArgs{
		Name:             pulumi.String(fullName + "-execution"),
		AssumeRolePolicy: pulumi.String(assumeRole),
	}, child...)
	if err != nil {
		return nil, err
	}

	if _, err := iam.NewRolePolicyAttachment(ctx, name+"-execution-managed", &iam.RolePolicyAttachmentArgs{
		Role:      execution.Name,
		PolicyArn: pulumi.String("arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"),
	}, child...); err != nil {
		return nil, err
	}

	// The scoping that matters: /forge-central/<stage>/<service>/* and nothing
	// else. A compromised sprue task cannot read hilt's AppRole secret_id, the
	// delegator's transactor key, or the OpenBao root token.
	secretsPolicy := iam.GetPolicyDocumentOutput(ctx, iam.GetPolicyDocumentOutputArgs{
		Statements: iam.GetPolicyDocumentStatementArray{
			iam.GetPolicyDocumentStatementArgs{
				Sid:       pulumi.String("ReadOwnParameters"),
				Actions:   pulumi.StringArray{pulumi.String("ssm:GetParameters"), pulumi.String("ssm:GetParameter")},
				Resources: pulumi.StringArray{pulumi.String(ssmPrefixArn)},
			},
			// Parameters are encrypted under the account's AWS-managed SSM key,
			// which has no ARN to name here without a lookup, so the grant is
			// bounded by the service that may use it. The ssm:GetParameter*
			// statement above is what keeps a task to its own prefix; this only
			// lets it decrypt what it may read.
			iam.GetPolicyDocumentStatementArgs{
				Sid:       pulumi.String("DecryptOwnParameters"),
				Actions:   pulumi.StringArray{pulumi.String("kms:Decrypt")},
				Resources: pulumi.StringArray{pulumi.String("*")},
				Conditions: iam.GetPolicyDocumentStatementConditionArray{
					iam.GetPolicyDocumentStatementConditionArgs{
						Test:     pulumi.String("StringEquals"),
						Variable: pulumi.String("kms:ViaService"),
						Values:   pulumi.StringArray{pulumi.String("ssm." + args.Region + ".amazonaws.com")},
					},
				},
			},
		},
	}, invoke).Json()

	if _, err := iam.NewRolePolicy(ctx, name+"-execution-secrets", &iam.RolePolicyArgs{
		Name:   pulumi.String("read-own-secrets"),
		Role:   execution.ID(),
		Policy: secretsPolicy,
	}, child...); err != nil {
		return nil, err
	}

	task, err := iam.NewRole(ctx, name+"-task-role", &iam.RoleArgs{
		Name:             pulumi.String(fullName + "-task"),
		AssumeRolePolicy: pulumi.String(assumeRole),
	}, child...)
	if err != nil {
		return nil, err
	}

	// Only sprue (S3) and the delegator (DynamoDB) need anything here. The
	// other four get a role with no permissions at all, which is deliberate.
	for _, policyName := range sortedKeys(args.TaskPolicies) {
		if _, err := iam.NewRolePolicy(ctx, name+"-task-"+policyName, &iam.RolePolicyArgs{
			Name:   pulumi.String(policyName),
			Role:   task.ID(),
			Policy: args.TaskPolicies[policyName],
		}, child...); err != nil {
			return nil, err
		}
	}

	return &serviceRoles{execution: execution, task: task}, nil
}

// --- routing --------------------------------------------------------------

// Public routing is created only for services that need a public identity.
//
// plc has no hostname, matching smelt, which gives it no Caddy route and no DNS
// record. It is reachable only over the private namespace.
type routing struct {
	targetGroup  *lb.TargetGroup
	listenerRule *lb.ListenerRule
	discovery    *servicediscovery.Service
}

func newRouting(ctx *pulumi.Context, name, fullName string, args *Args, child []pulumi.ResourceOption) (*routing, error) {
	built := &routing{}

	if args.Hostname != nil {
		targetGroup, err := lb.NewTargetGroup(ctx, name+"-target-group", &lb.TargetGroupArgs{
			// A target group name is capped at 32 characters.
			Name:       pulumi.String(truncate(fullName, 32)),
			Port:       pulumi.Int(args.ContainerPort),
			Protocol:   pulumi.String("HTTP"),
			TargetType: pulumi.String("ip"),
			VpcId:      args.VpcID,

			HealthCheck: &lb.TargetGroupHealthCheckArgs{
				// Services disagree: /health for sprue, hilt and swarf,
				// /healthcheck for the delegator and signing service, /_health
				// for plc.
				Path:               pulumi.String(args.HealthCheckPath),
				Matcher:            pulumi.String("200"),
				Interval:           pulumi.Int(30),
				Timeout:            pulumi.Int(5),
				HealthyThreshold:   pulumi.Int(2),
				UnhealthyThreshold: pulumi.Int(3),
			},

			// Long enough to finish an in-flight request, short enough that a
			// deploy does not stall. Swarf's SSE streams are cut at this point
			// rather than held.
			DeregistrationDelay: pulumi.Int(30),
		},
			// Terraform needed create_before_destroy spelled out here. Pulumi
			// replaces by creating the new resource first by default, so the
			// name collision this avoided cannot happen unless a caller asks
			// for delete-before-replace.
			child...)
		if err != nil {
			return nil, err
		}
		built.targetGroup = targetGroup

		listenerRule, err := lb.NewListenerRule(ctx, name+"-listener-rule", &lb.ListenerRuleArgs{
			ListenerArn: args.ListenerArn,
			Priority:    pulumi.Int(args.ListenerPriority),
			Actions: lb.ListenerRuleActionArray{
				&lb.ListenerRuleActionArgs{
					Type:           pulumi.String("forward"),
					TargetGroupArn: targetGroup.Arn,
				},
			},
			Conditions: lb.ListenerRuleConditionArray{
				&lb.ListenerRuleConditionArgs{
					HostHeader: &lb.ListenerRuleConditionHostHeaderArgs{
						Values: pulumi.StringArray{args.Hostname.ToStringOutput()},
					},
				},
			},
		}, child...)
		if err != nil {
			return nil, err
		}
		built.listenerRule = listenerRule

		if _, err := route53.NewRecord(ctx, name+"-record", &route53.RecordArgs{
			ZoneId: args.Route53ZoneID,
			Name:   args.Hostname,
			Type:   pulumi.String("A"),
			Aliases: route53.RecordAliasArray{
				&route53.RecordAliasArgs{
					Name:                 args.AlbDNSName,
					ZoneId:               args.AlbZoneID,
					EvaluateTargetHealth: pulumi.Bool(true),
				},
			},
		}, child...); err != nil {
			return nil, err
		}
	}

	// Private DNS for callers inside the VPC. hilt reaches OpenBao this way, and
	// sprue and hilt reach plc this way.
	if args.RegisterInternal {
		discovery, err := servicediscovery.NewService(ctx, name+"-discovery", &servicediscovery.ServiceArgs{
			Name: pulumi.String(args.Service),

			// ECS registers the running task as an instance here, and Cloud Map
			// refuses to delete a service that still holds one. Replacing this
			// resource therefore deadlocks against the task it serves: the
			// registration only moves once the ECS service is updated, which
			// happens after the delete. This lets the provider clear the
			// instances itself.
			ForceDestroy: pulumi.Bool(true),

			DnsConfig: &servicediscovery.ServiceDnsConfigArgs{
				NamespaceId: args.NamespaceID,
				DnsRecords: servicediscovery.ServiceDnsConfigDnsRecordArray{
					&servicediscovery.ServiceDnsConfigDnsRecordArgs{
						Type: pulumi.String("A"),
						Ttl:  pulumi.Int(10),
					},
				},
				RoutingPolicy: pulumi.String("MULTIVALUE"),
			},

			// Required for ECS to report task health for the registered
			// instance, and it cannot be added to an existing service, so
			// dropping it would mean replacing this service to get it back.
			// health_check_config, which the provider recommends instead,
			// serves public namespaces only; this one is private.
			//
			// FailureThreshold is deprecated and AWS always applies 1, so the
			// value here is inert. It is stated anyway because an empty block
			// is not sent at all: CreateService then records no custom health
			// config, the next read finds none where the configuration declares
			// one, and every preview schedules another replacement that lands in
			// the same state. The deprecation warning is the price of a service
			// that stops being recreated on every up.
			HealthCheckCustomConfig: &servicediscovery.ServiceHealthCheckCustomConfigArgs{
				FailureThreshold: pulumi.Int(1),
			},
		}, child...)
		if err != nil {
			return nil, err
		}
		built.discovery = discovery
	}

	return built, nil
}

func truncate(value string, limit int) string {
	if len(value) <= limit {
		return value
	}

	return value[:limit]
}
