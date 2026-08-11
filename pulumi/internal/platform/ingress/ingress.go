// Package ingress builds one ALB for the whole stage, with host-based routing to
// each service.
//
// Public hostnames are not cosmetic here. Services identify each other by
// did:web, which resolves by fetching https://<host>/.well-known/did.json, so
// every service that other services authenticate must be reachable at a real
// name with a real certificate.
package ingress

import (
	"fmt"

	"github.com/pulumi/pulumi-aws/sdk/v7/go/aws/acm"
	"github.com/pulumi/pulumi-aws/sdk/v7/go/aws/lb"
	"github.com/pulumi/pulumi-aws/sdk/v7/go/aws/route53"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
)

// Args configures the load balancer and its certificate.
type Args struct {
	Stage string

	// ZoneName is an existing Route53 hosted zone, e.g. fil.one.
	ZoneName string

	// HostnameSuffix is the suffix every service hostname shares, e.g.
	// dev.fil.one. Services are reachable at <service>.<suffix>.
	HostnameSuffix string

	PublicSubnetIDs pulumi.StringArrayInput
	SecurityGroupID pulumi.StringInput

	// IdleTimeout in seconds must exceed the quiet period of swarf's SSE
	// firehose, not just its request time. Zero defaults to 3600.
	IdleTimeout int

	DeletionProtection bool
}

// Ingress is a stage's load balancer, certificate and listeners.
type Ingress struct {
	pulumi.ResourceState

	ListenerArn   pulumi.StringOutput
	DNSName       pulumi.StringOutput
	ZoneID        pulumi.StringOutput
	Route53ZoneID pulumi.StringOutput
}

// New builds the ingress.
func New(ctx *pulumi.Context, name string, args *Args, opts ...pulumi.ResourceOption) (*Ingress, error) {
	if args.Stage == "" || args.ZoneName == "" || args.HostnameSuffix == "" {
		return nil, fmt.Errorf("ingress: stage, zone name and hostname suffix are all required")
	}
	if args.IdleTimeout == 0 {
		args.IdleTimeout = 3600
	}

	component := &Ingress{}
	if err := ctx.RegisterComponentResource("forge:index:Ingress", name, component, opts...); err != nil {
		return nil, err
	}

	child := []pulumi.ResourceOption{pulumi.Parent(component)}
	fullName := "fc-" + args.Stage

	zone, err := route53.LookupZone(ctx, &route53.LookupZoneArgs{
		Name:        pulumi.StringRef(args.ZoneName),
		PrivateZone: pulumi.BoolRef(false),
	}, pulumi.InvokeOption(pulumi.Parent(component)))
	if err != nil {
		return nil, fmt.Errorf("ingress: look up hosted zone %q: %w", args.ZoneName, err)
	}

	balancer, err := lb.NewLoadBalancer(ctx, name+"-alb", &lb.LoadBalancerArgs{
		Name:             pulumi.String(fullName),
		LoadBalancerType: pulumi.String("application"),
		SecurityGroups:   pulumi.StringArray{args.SecurityGroupID.ToStringOutput()},
		Subnets:          args.PublicSubnetIDs,

		// Swarf's /revocations/:since is a Server-Sent Events firehose that
		// clients hold open indefinitely. The ALB default of 60 seconds would
		// sever every subscriber on a quiet minute.
		IdleTimeout: pulumi.Int(args.IdleTimeout),

		EnableDeletionProtection: pulumi.Bool(args.DeletionProtection),

		Tags: pulumi.StringMap{"Name": pulumi.String(fullName)},
	}, child...)
	if err != nil {
		return nil, err
	}

	// One wildcard certificate covers every service hostname in the stage, so
	// adding a service does not mean waiting on certificate validation.
	//
	// Terraform needed create_before_destroy here. Pulumi creates a replacement
	// before deleting the original by default, so a certificate still attached to
	// the listener is never deleted out from under it.
	certificate, err := acm.NewCertificate(ctx, name+"-certificate", &acm.CertificateArgs{
		DomainName:              pulumi.String("*." + args.HostnameSuffix),
		ValidationMethod:        pulumi.String("DNS"),
		SubjectAlternativeNames: pulumi.StringArray{pulumi.String(args.HostnameSuffix)},
		Tags:                    pulumi.StringMap{"Name": pulumi.String(fullName)},
	}, child...)
	if err != nil {
		return nil, err
	}

	// The wildcard and the apex validate through the same record, so there is one
	// record to write rather than one per name. Terraform expressed that by
	// filtering the apex out of the option set; here the first option is taken,
	// which is the same record either way because both options carry identical
	// name, type and value.
	option := certificate.DomainValidationOptions.Index(pulumi.Int(0))

	validationRecord, err := route53.NewRecord(ctx, name+"-certificate-validation", &route53.RecordArgs{
		ZoneId:  pulumi.String(zone.ZoneId),
		Name:    option.ResourceRecordName().Elem(),
		Type:    option.ResourceRecordType().Elem(),
		Records: pulumi.StringArray{option.ResourceRecordValue().Elem()},
		Ttl:     pulumi.Int(60),

		AllowOverwrite: pulumi.Bool(true),
	}, child...)
	if err != nil {
		return nil, err
	}

	validation, err := acm.NewCertificateValidation(ctx, name+"-validation", &acm.CertificateValidationArgs{
		CertificateArn:        certificate.Arn,
		ValidationRecordFqdns: pulumi.StringArray{validationRecord.Fqdn},
	}, child...)
	if err != nil {
		return nil, err
	}

	httpsListener, err := lb.NewListener(ctx, name+"-https", &lb.ListenerArgs{
		LoadBalancerArn: balancer.Arn,
		Port:            pulumi.Int(443),
		Protocol:        pulumi.String("HTTPS"),
		SslPolicy:       pulumi.String("ELBSecurityPolicy-TLS13-1-2-2021-06"),
		CertificateArn:  validation.CertificateArn,

		// Services attach their own host-based rules. Anything unmatched is a
		// misconfigured DNS record rather than traffic worth guessing about.
		DefaultActions: lb.ListenerDefaultActionArray{
			&lb.ListenerDefaultActionArgs{
				Type: pulumi.String("fixed-response"),
				FixedResponse: &lb.ListenerDefaultActionFixedResponseArgs{
					ContentType: pulumi.String("text/plain"),
					MessageBody: pulumi.String("no service is routed at this hostname"),
					StatusCode:  pulumi.String("404"),
				},
			},
		},
	}, child...)
	if err != nil {
		return nil, err
	}

	if _, err := lb.NewListener(ctx, name+"-http-redirect", &lb.ListenerArgs{
		LoadBalancerArn: balancer.Arn,
		Port:            pulumi.Int(80),
		Protocol:        pulumi.String("HTTP"),

		DefaultActions: lb.ListenerDefaultActionArray{
			&lb.ListenerDefaultActionArgs{
				Type: pulumi.String("redirect"),
				Redirect: &lb.ListenerDefaultActionRedirectArgs{
					Port:       pulumi.String("443"),
					Protocol:   pulumi.String("HTTPS"),
					StatusCode: pulumi.String("HTTP_301"),
				},
			},
		},
	}, child...); err != nil {
		return nil, err
	}

	component.ListenerArn = httpsListener.Arn
	component.DNSName = balancer.DnsName
	component.ZoneID = balancer.ZoneId
	component.Route53ZoneID = pulumi.String(zone.ZoneId).ToStringOutput()

	if err := ctx.RegisterResourceOutputs(component, pulumi.Map{
		"listenerArn":   component.ListenerArn,
		"dnsName":       component.DNSName,
		"zoneId":        component.ZoneID,
		"route53ZoneId": component.Route53ZoneID,
	}); err != nil {
		return nil, err
	}

	return component, nil
}
