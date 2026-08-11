// Package database creates one RDS Postgres instance shared by every service,
// each with its own database and owning role.
//
// The roles and databases themselves are not resources here. The Pulumi program
// runs outside the VPC and cannot reach RDS, so the provision Lambda creates
// them from inside the private subnets instead.
package database

import (
	"fmt"

	"github.com/pulumi/pulumi-aws/sdk/v7/go/aws/rds"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
)

// Args configures the instance.
type Args struct {
	Stage string

	// SubnetIDs are the private subnets, at least two AZs.
	SubnetIDs       pulumi.StringArrayInput
	SecurityGroupID pulumi.StringInput

	// EngineVersion defaults to 16.
	EngineVersion string

	// InstanceClass is sized per stage. Mind max_connections, which scales with
	// memory: roughly DBInstanceClassMemory/9531392, about 112 on a
	// db.t4g.micro. OpenBao's max parallel plus each service's max_conns has to
	// fit inside it. Empty defaults to db.t4g.micro.
	InstanceClass string

	// AllocatedStorage defaults to 20 GiB, MaxAllocatedStorage to 100: the upper
	// bound for storage autoscaling.
	AllocatedStorage    int
	MaxAllocatedStorage int

	// MasterUsername defaults to forge_admin.
	MasterUsername string

	// MultiAZ matters because regional appliances cannot boot while OpenBao is
	// down, and OpenBao stores its data here.
	MultiAZ bool

	BackupRetentionDays int

	DeletionProtection         bool
	SkipFinalSnapshot          bool
	PerformanceInsightsEnabled bool
}

// Database is a stage's Postgres instance.
type Database struct {
	pulumi.ResourceState

	Address pulumi.StringOutput
	Port    pulumi.IntOutput

	// MasterSecretArn is the Secrets Manager secret RDS manages itself. Read by
	// the provision Lambda; never by this program.
	MasterSecretArn      pulumi.StringOutput
	MasterSecretKmsKeyID pulumi.StringOutput
}

// New creates the subnet group and the instance.
func New(ctx *pulumi.Context, name string, args *Args, opts ...pulumi.ResourceOption) (*Database, error) {
	if args.Stage == "" {
		return nil, fmt.Errorf("database: stage is required")
	}
	if args.SubnetIDs == nil || args.SecurityGroupID == nil {
		return nil, fmt.Errorf("database: subnets and a security group are both required")
	}

	if args.EngineVersion == "" {
		args.EngineVersion = "16"
	}
	if args.InstanceClass == "" {
		args.InstanceClass = "db.t4g.micro"
	}
	if args.AllocatedStorage == 0 {
		args.AllocatedStorage = 20
	}
	if args.MaxAllocatedStorage == 0 {
		args.MaxAllocatedStorage = 100
	}
	if args.MasterUsername == "" {
		args.MasterUsername = "forge_admin"
	}
	if args.BackupRetentionDays == 0 {
		args.BackupRetentionDays = 7
	}

	component := &Database{}
	if err := ctx.RegisterComponentResource("forge:index:Database", name, component, opts...); err != nil {
		return nil, err
	}

	child := []pulumi.ResourceOption{pulumi.Parent(component)}
	fullName := "fc-" + args.Stage

	subnetGroup, err := rds.NewSubnetGroup(ctx, name+"-subnets", &rds.SubnetGroupArgs{
		Name:      pulumi.String(fullName),
		SubnetIds: args.SubnetIDs,
		Tags:      pulumi.StringMap{"Name": pulumi.String(fullName)},
	}, child...)
	if err != nil {
		return nil, err
	}

	instanceArgs := &rds.InstanceArgs{
		Identifier:    pulumi.String(fullName),
		Engine:        pulumi.String("postgres"),
		EngineVersion: pulumi.String(args.EngineVersion),
		InstanceClass: pulumi.String(args.InstanceClass),

		AllocatedStorage:    pulumi.Int(args.AllocatedStorage),
		MaxAllocatedStorage: pulumi.Int(args.MaxAllocatedStorage),
		StorageType:         pulumi.String("gp3"),
		StorageEncrypted:    pulumi.Bool(true),

		// DbName is left unset: databases are created per service by the
		// provision Lambda.
		Username: pulumi.String(args.MasterUsername),

		// RDS generates the master password and keeps it in Secrets Manager, so
		// it never appears in stack state or in a configuration file. The
		// provision Lambda reads it from there when it creates the per-service
		// roles.
		ManageMasterUserPassword: pulumi.Bool(true),

		DbSubnetGroupName:   subnetGroup.Name,
		VpcSecurityGroupIds: pulumi.StringArray{args.SecurityGroupID.ToStringOutput()},
		PubliclyAccessible:  pulumi.Bool(false),

		MultiAz: pulumi.Bool(args.MultiAZ),

		BackupRetentionPeriod: pulumi.Int(args.BackupRetentionDays),
		CopyTagsToSnapshot:    pulumi.Bool(true),

		// OpenBao stores its data here, so losing this instance means losing
		// every regional appliance's ability to unseal.
		DeletionProtection: pulumi.Bool(args.DeletionProtection),
		SkipFinalSnapshot:  pulumi.Bool(args.SkipFinalSnapshot),

		AutoMinorVersionUpgrade:    pulumi.Bool(true),
		PerformanceInsightsEnabled: pulumi.Bool(args.PerformanceInsightsEnabled),

		Tags: pulumi.StringMap{"Name": pulumi.String(fullName)},
	}

	if !args.SkipFinalSnapshot {
		instanceArgs.FinalSnapshotIdentifier = pulumi.String(fullName + "-final")
	}

	// RDS accepts a subnet group change only when it also moves the instance to
	// another VPC, so a renamed subnet group cannot be applied to a live
	// instance. Replace the instance along with the group instead of failing on
	// ModifyDBInstance. This is Terraform's replace_triggered_by, expressed
	// against the property that carries the change.
	instanceOpts := append(child, pulumi.ReplaceOnChanges([]string{"dbSubnetGroupName"}))

	instance, err := rds.NewInstance(ctx, name+"-instance", instanceArgs, instanceOpts...)
	if err != nil {
		return nil, err
	}

	component.Address = instance.Address
	component.Port = instance.Port

	// manage_master_user_password gives exactly one secret, so index 0 is the
	// whole of it.
	component.MasterSecretArn = instance.MasterUserSecrets.Index(pulumi.Int(0)).SecretArn().Elem()
	component.MasterSecretKmsKeyID = instance.MasterUserSecrets.Index(pulumi.Int(0)).KmsKeyId().Elem()

	if err := ctx.RegisterResourceOutputs(component, pulumi.Map{
		"address": component.Address,
		"port":    component.Port,
	}); err != nil {
		return nil, err
	}

	return component, nil
}
