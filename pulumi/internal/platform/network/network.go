// Package network builds the VPC, subnets and the security groups every other
// module attaches to.
//
// Egress is not optional here. Tasks pull images from GHCR, call the public
// Filecoin RPC, and resolve each other's did:web identities over HTTPS, which
// means a task in a private subnet reaches the public ALB back through the NAT
// gateway. A design without NAT would need a private DNS override per service
// hostname and would still leave the chain RPC unreachable.
package network

import (
	"fmt"
	"net"

	"github.com/apparentlymart/go-cidr/cidr"
	"github.com/pulumi/pulumi-aws/sdk/v7/go/aws"
	"github.com/pulumi/pulumi-aws/sdk/v7/go/aws/ec2"
	"github.com/pulumi/pulumi-aws/sdk/v7/go/aws/servicediscovery"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
)

// Args configures the network.
type Args struct {
	// Stage namespaces every resource, e.g. dev or prod.
	Stage string

	// VpcCIDR must leave room for four /20 subnets. Empty defaults to
	// 10.20.0.0/16.
	VpcCIDR string
}

// Network is a stage's VPC and its security groups.
type Network struct {
	pulumi.ResourceState

	VpcID            pulumi.StringOutput
	PublicSubnetIDs  pulumi.StringArray
	PrivateSubnetIDs pulumi.StringArray

	// PrivateSubnetCIDRs bounds hilt's AppRole token to the VPC. Coarse by
	// nature: it separates the VPC from the internet, not one task from another.
	PrivateSubnetCIDRs pulumi.StringArray

	AlbSecurityGroupID      pulumi.StringOutput
	ServiceSecurityGroupID  pulumi.StringOutput
	LambdaSecurityGroupID   pulumi.StringOutput
	DatabaseSecurityGroupID pulumi.StringOutput

	NamespaceID   pulumi.StringOutput
	NamespaceName pulumi.StringOutput
}

// New builds the network.
func New(ctx *pulumi.Context, name string, args *Args, opts ...pulumi.ResourceOption) (*Network, error) {
	if args.Stage == "" {
		return nil, fmt.Errorf("network: stage is required")
	}
	if args.VpcCIDR == "" {
		args.VpcCIDR = "10.20.0.0/16"
	}

	component := &Network{}
	if err := ctx.RegisterComponentResource("forge:index:Network", name, component, opts...); err != nil {
		return nil, err
	}

	child := []pulumi.ResourceOption{pulumi.Parent(component)}
	fullName := "fc-" + args.Stage

	// Two AZs is the minimum RDS multi-AZ and the ALB both require.
	available, err := aws.GetAvailabilityZones(ctx, &aws.GetAvailabilityZonesArgs{
		State: pulumi.StringRef("available"),
	}, pulumi.InvokeOption(pulumi.Parent(component)))
	if err != nil {
		return nil, fmt.Errorf("network: look up availability zones: %w", err)
	}
	if len(available.Names) < 2 {
		return nil, fmt.Errorf("network: %d availability zones available, need at least 2", len(available.Names))
	}
	azs := available.Names[:2]

	vpc, err := ec2.NewVpc(ctx, name+"-vpc", &ec2.VpcArgs{
		CidrBlock:          pulumi.String(args.VpcCIDR),
		EnableDnsSupport:   pulumi.Bool(true),
		EnableDnsHostnames: pulumi.Bool(true),
		Tags:               pulumi.StringMap{"Name": pulumi.String(fullName)},
	}, child...)
	if err != nil {
		return nil, err
	}

	gateway, err := ec2.NewInternetGateway(ctx, name+"-igw", &ec2.InternetGatewayArgs{
		VpcId: vpc.ID(),
		Tags:  pulumi.StringMap{"Name": pulumi.String(fullName)},
	}, child...)
	if err != nil {
		return nil, err
	}

	layout, err := subnetLayout(args.VpcCIDR, len(azs))
	if err != nil {
		return nil, fmt.Errorf("network: %w", err)
	}

	publicSubnets := make([]*ec2.Subnet, 0, len(azs))
	privateSubnets := make([]*ec2.Subnet, 0, len(azs))

	for index, az := range azs {
		subnet, err := ec2.NewSubnet(ctx, fmt.Sprintf("%s-public-%s", name, az), &ec2.SubnetArgs{
			VpcId:               vpc.ID(),
			AvailabilityZone:    pulumi.String(az),
			CidrBlock:           pulumi.String(layout.public[index]),
			MapPublicIpOnLaunch: pulumi.Bool(true),
			Tags:                pulumi.StringMap{"Name": pulumi.String(fmt.Sprintf("%s-public-%s", fullName, az))},
		}, child...)
		if err != nil {
			return nil, err
		}
		publicSubnets = append(publicSubnets, subnet)
	}

	for index, az := range azs {
		subnet, err := ec2.NewSubnet(ctx, fmt.Sprintf("%s-private-%s", name, az), &ec2.SubnetArgs{
			VpcId:            vpc.ID(),
			AvailabilityZone: pulumi.String(az),
			CidrBlock:        pulumi.String(layout.private[index]),
			Tags:             pulumi.StringMap{"Name": pulumi.String(fmt.Sprintf("%s-private-%s", fullName, az))},
		}, child...)
		if err != nil {
			return nil, err
		}
		privateSubnets = append(privateSubnets, subnet)
	}

	// One NAT gateway rather than one per AZ. It is a single point of failure for
	// egress and roughly halves the standing cost; raising it to one per AZ is a
	// per-stage decision rather than a rewrite.
	address, err := ec2.NewEip(ctx, name+"-nat-eip", &ec2.EipArgs{
		Domain: pulumi.String("vpc"),
		Tags:   pulumi.StringMap{"Name": pulumi.String(fullName + "-nat")},
	}, child...)
	if err != nil {
		return nil, err
	}

	nat, err := ec2.NewNatGateway(ctx, name+"-nat", &ec2.NatGatewayArgs{
		AllocationId: address.ID(),
		SubnetId:     publicSubnets[0].ID(),
		Tags:         pulumi.StringMap{"Name": pulumi.String(fullName)},
	}, append(child, pulumi.DependsOn([]pulumi.Resource{gateway}))...)
	if err != nil {
		return nil, err
	}

	publicRoutes, err := ec2.NewRouteTable(ctx, name+"-public-routes", &ec2.RouteTableArgs{
		VpcId: vpc.ID(),
		Routes: ec2.RouteTableRouteArray{
			&ec2.RouteTableRouteArgs{
				CidrBlock: pulumi.String("0.0.0.0/0"),
				GatewayId: gateway.ID(),
			},
		},
		Tags: pulumi.StringMap{"Name": pulumi.String(fullName + "-public")},
	}, child...)
	if err != nil {
		return nil, err
	}

	privateRoutes, err := ec2.NewRouteTable(ctx, name+"-private-routes", &ec2.RouteTableArgs{
		VpcId: vpc.ID(),
		Routes: ec2.RouteTableRouteArray{
			&ec2.RouteTableRouteArgs{
				CidrBlock:    pulumi.String("0.0.0.0/0"),
				NatGatewayId: nat.ID(),
			},
		},
		Tags: pulumi.StringMap{"Name": pulumi.String(fullName + "-private")},
	}, child...)
	if err != nil {
		return nil, err
	}

	for index, subnet := range publicSubnets {
		if _, err := ec2.NewRouteTableAssociation(ctx, fmt.Sprintf("%s-public-%s-routes", name, azs[index]), &ec2.RouteTableAssociationArgs{
			SubnetId:     subnet.ID(),
			RouteTableId: publicRoutes.ID(),
		}, child...); err != nil {
			return nil, err
		}
	}

	for index, subnet := range privateSubnets {
		if _, err := ec2.NewRouteTableAssociation(ctx, fmt.Sprintf("%s-private-%s-routes", name, azs[index]), &ec2.RouteTableAssociationArgs{
			SubnetId:     subnet.ID(),
			RouteTableId: privateRoutes.ID(),
		}, child...); err != nil {
			return nil, err
		}
	}

	// Private DNS for service-to-service calls that do not need a public
	// identity: plc, which smelt also keeps unrouted, and OpenBao's internal
	// address for hilt.
	namespace, err := servicediscovery.NewPrivateDnsNamespace(ctx, name+"-namespace", &servicediscovery.PrivateDnsNamespaceArgs{
		Name: pulumi.String("forge-central.internal"),
		Vpc:  vpc.ID(),
	}, child...)
	if err != nil {
		return nil, err
	}

	groups, err := newSecurityGroups(ctx, name, fullName, vpc, child)
	if err != nil {
		return nil, err
	}

	component.VpcID = vpc.ID().ToStringOutput()
	component.NamespaceID = namespace.ID().ToStringOutput()
	component.NamespaceName = namespace.Name
	component.AlbSecurityGroupID = groups.alb.ID().ToStringOutput()
	component.ServiceSecurityGroupID = groups.service.ID().ToStringOutput()
	component.LambdaSecurityGroupID = groups.lambda.ID().ToStringOutput()
	component.DatabaseSecurityGroupID = groups.database.ID().ToStringOutput()

	for _, subnet := range publicSubnets {
		component.PublicSubnetIDs = append(component.PublicSubnetIDs, subnet.ID().ToStringOutput())
	}
	for _, subnet := range privateSubnets {
		component.PrivateSubnetIDs = append(component.PrivateSubnetIDs, subnet.ID().ToStringOutput())
		component.PrivateSubnetCIDRs = append(component.PrivateSubnetCIDRs, subnet.CidrBlock)
	}

	if err := ctx.RegisterResourceOutputs(component, pulumi.Map{
		"vpcId":         component.VpcID,
		"namespaceId":   component.NamespaceID,
		"namespaceName": component.NamespaceName,
	}); err != nil {
		return nil, err
	}

	return component, nil
}

// securityGroups is the set every other module attaches to. They are created in
// dependency order: the service group names both the load balancer's group and
// the Lambda's, and the database group names the service and Lambda groups.
type securityGroups struct {
	alb      *ec2.SecurityGroup
	service  *ec2.SecurityGroup
	lambda   *ec2.SecurityGroup
	database *ec2.SecurityGroup
}

func newSecurityGroups(ctx *pulumi.Context, name, fullName string, vpc *ec2.Vpc, child []pulumi.ResourceOption) (*securityGroups, error) {
	alb, err := ec2.NewSecurityGroup(ctx, name+"-alb-sg", &ec2.SecurityGroupArgs{
		Name:        pulumi.String(fullName + "-alb"),
		Description: pulumi.String("Public ingress to the Forge load balancer"),
		VpcId:       vpc.ID(),

		Ingress: ec2.SecurityGroupIngressArray{
			&ec2.SecurityGroupIngressArgs{
				Description: pulumi.String("HTTPS from anywhere"),
				FromPort:    pulumi.Int(443),
				ToPort:      pulumi.Int(443),
				Protocol:    pulumi.String("tcp"),
				CidrBlocks:  pulumi.StringArray{pulumi.String("0.0.0.0/0")},
			},
			&ec2.SecurityGroupIngressArgs{
				Description: pulumi.String("HTTP, redirected to HTTPS"),
				FromPort:    pulumi.Int(80),
				ToPort:      pulumi.Int(80),
				Protocol:    pulumi.String("tcp"),
				CidrBlocks:  pulumi.StringArray{pulumi.String("0.0.0.0/0")},
			},
		},

		Egress: ec2.SecurityGroupEgressArray{
			&ec2.SecurityGroupEgressArgs{
				Description: pulumi.String("To the service tasks"),
				FromPort:    pulumi.Int(0),
				ToPort:      pulumi.Int(0),
				Protocol:    pulumi.String("-1"),
				CidrBlocks:  pulumi.StringArray{pulumi.String("0.0.0.0/0")},
			},
		},

		Tags: pulumi.StringMap{"Name": pulumi.String(fullName + "-alb")},
	}, child...)
	if err != nil {
		return nil, err
	}

	lambda, err := ec2.NewSecurityGroup(ctx, name+"-lambda-sg", &ec2.SecurityGroupArgs{
		Name:        pulumi.String(fullName + "-lambda"),
		Description: pulumi.String("The provision Lambda, which needs RDS and OpenBao"),
		VpcId:       vpc.ID(),

		Egress: ec2.SecurityGroupEgressArray{
			&ec2.SecurityGroupEgressArgs{
				Description: pulumi.String("RDS, OpenBao, and the SSM and Secrets Manager APIs"),
				FromPort:    pulumi.Int(0),
				ToPort:      pulumi.Int(0),
				Protocol:    pulumi.String("-1"),
				CidrBlocks:  pulumi.StringArray{pulumi.String("0.0.0.0/0")},
			},
		},

		Tags: pulumi.StringMap{"Name": pulumi.String(fullName + "-lambda")},
	}, child...)
	if err != nil {
		return nil, err
	}

	service, err := ec2.NewSecurityGroup(ctx, name+"-service-sg", &ec2.SecurityGroupArgs{
		Name:        pulumi.String(fullName + "-service"),
		Description: pulumi.String("Forge ECS tasks"),
		VpcId:       vpc.ID(),

		Ingress: ec2.SecurityGroupIngressArray{
			&ec2.SecurityGroupIngressArgs{
				Description:    pulumi.String("From the load balancer"),
				FromPort:       pulumi.Int(0),
				ToPort:         pulumi.Int(65535),
				Protocol:       pulumi.String("tcp"),
				SecurityGroups: pulumi.StringArray{alb.ID().ToStringOutput()},
			},
			&ec2.SecurityGroupIngressArgs{
				Description: pulumi.String("Between tasks, for plc and OpenBao over private DNS"),
				FromPort:    pulumi.Int(0),
				ToPort:      pulumi.Int(65535),
				Protocol:    pulumi.String("tcp"),
				Self:        pulumi.Bool(true),
			},
			// The Lambda reaches OpenBao over the same private path hilt uses,
			// so the task group has to accept it. Declared inline rather than as
			// a separate rule resource: the inline set is authoritative for a
			// group, and a rule declared outside one is stripped on the next up.
			&ec2.SecurityGroupIngressArgs{
				Description:    pulumi.String("OpenBao from the provision Lambda"),
				FromPort:       pulumi.Int(0),
				ToPort:         pulumi.Int(65535),
				Protocol:       pulumi.String("tcp"),
				SecurityGroups: pulumi.StringArray{lambda.ID().ToStringOutput()},
			},
		},

		Egress: ec2.SecurityGroupEgressArray{
			&ec2.SecurityGroupEgressArgs{
				Description: pulumi.String("Image pulls, chain RPC, and did:web resolution"),
				FromPort:    pulumi.Int(0),
				ToPort:      pulumi.Int(0),
				Protocol:    pulumi.String("-1"),
				CidrBlocks:  pulumi.StringArray{pulumi.String("0.0.0.0/0")},
			},
		},

		Tags: pulumi.StringMap{"Name": pulumi.String(fullName + "-service")},
	}, child...)
	if err != nil {
		return nil, err
	}

	database, err := ec2.NewSecurityGroup(ctx, name+"-database-sg", &ec2.SecurityGroupArgs{
		Name:        pulumi.String(fullName + "-database"),
		Description: pulumi.String("RDS Postgres, reachable only from tasks and the provision Lambda"),
		VpcId:       vpc.ID(),

		Ingress: ec2.SecurityGroupIngressArray{
			&ec2.SecurityGroupIngressArgs{
				Description:    pulumi.String("Postgres from the service tasks"),
				FromPort:       pulumi.Int(5432),
				ToPort:         pulumi.Int(5432),
				Protocol:       pulumi.String("tcp"),
				SecurityGroups: pulumi.StringArray{service.ID().ToStringOutput()},
			},
			&ec2.SecurityGroupIngressArgs{
				Description:    pulumi.String("Postgres from the provision Lambda"),
				FromPort:       pulumi.Int(5432),
				ToPort:         pulumi.Int(5432),
				Protocol:       pulumi.String("tcp"),
				SecurityGroups: pulumi.StringArray{lambda.ID().ToStringOutput()},
			},
		},

		Tags: pulumi.StringMap{"Name": pulumi.String(fullName + "-database")},
	}, child...)
	if err != nil {
		return nil, err
	}

	return &securityGroups{alb: alb, service: service, lambda: lambda, database: database}, nil
}

// addresses is a stage's subnet layout: one public and one private range per
// availability zone.
type addresses struct {
	public  []string
	private []string
}

// subnetLayout carves the ranges out of the VPC CIDR.
//
// Public subnets take the first blocks and private the next, so the offset by the
// number of zones is what keeps the two ranges from overlapping. Four bits gives
// /20s out of a /16, which is the shape the default CIDR is chosen for.
//
// The arithmetic is go-cidr's, the same library Terraform's own cidrsubnet is
// built on, so the addresses are the ones the stage has always had. What is stated
// here is only the layout, which is the part worth pinning.
func subnetLayout(vpcCIDR string, zones int) (*addresses, error) {
	_, network, err := net.ParseCIDR(vpcCIDR)
	if err != nil {
		return nil, fmt.Errorf("parse vpc cidr %q: %w", vpcCIDR, err)
	}

	const newBits = 4

	layout := &addresses{
		public:  make([]string, 0, zones),
		private: make([]string, 0, zones),
	}

	for index := 0; index < zones; index++ {
		public, err := cidr.Subnet(network, newBits, index)
		if err != nil {
			return nil, fmt.Errorf("public subnet %d of %q: %w", index, vpcCIDR, err)
		}

		private, err := cidr.Subnet(network, newBits, index+zones)
		if err != nil {
			return nil, fmt.Errorf("private subnet %d of %q: %w", index, vpcCIDR, err)
		}

		layout.public = append(layout.public, public.String())
		layout.private = append(layout.private, private.String())
	}

	return layout, nil
}
