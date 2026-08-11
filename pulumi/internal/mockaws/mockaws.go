// Package mockaws is a Pulumi resource monitor that stands in for AWS in tests.
//
// It exists so the components in this tree can be built without credentials, a
// backend or a network. That is worth a package of its own here: the migration from
// Terraform replaced an interpolation language with Go, and the values that used to
// be strings are now outputs threaded through applies. A mocked run is what proves
// those applies resolve, that every resource's inputs are accepted, and that no
// output is read before it exists.
package mockaws

import (
	"fmt"

	"github.com/pulumi/pulumi/sdk/v3/go/common/resource"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
)

// Region is the region every mocked lookup reports.
const Region = "us-east-2"

// AccountID is the account every mocked lookup reports. It is the non-prod
// account, so a test that also builds a provider with the non-prod guard agrees
// with itself.
const AccountID = "654654381893"

// Monitor answers the provider calls the components make.
type Monitor struct{}

// Call answers a provider function. Only the four this project invokes are
// implemented; anything else is an error rather than an empty result, so a new
// lookup added to the components shows up here as a failing test rather than as a
// silently empty value.
func (Monitor) Call(args pulumi.MockCallArgs) (resource.PropertyMap, error) {
	switch args.Token {
	case "aws:index/getCallerIdentity:getCallerIdentity":
		return resource.NewPropertyMapFromMap(map[string]interface{}{
			"accountId": AccountID,
			"arn":       fmt.Sprintf("arn:aws:iam::%s:role/test", AccountID),
			"id":        AccountID,
			"userId":    "AIDATEST",
		}), nil

	case "aws:index/getRegion:getRegion":
		return resource.NewPropertyMapFromMap(map[string]interface{}{
			"description": "US East (Ohio)",
			"endpoint":    "ec2." + Region + ".amazonaws.com",
			"id":          Region,
			"name":        Region,
			"region":      Region,
		}), nil

	case "aws:index/getAvailabilityZones:getAvailabilityZones":
		return resource.NewPropertyMapFromMap(map[string]interface{}{
			"id":      Region,
			"names":   []interface{}{Region + "a", Region + "b", Region + "c"},
			"zoneIds": []interface{}{"use2-az1", "use2-az2", "use2-az3"},
		}), nil

	case "aws:route53/getZone:getZone":
		return resource.NewPropertyMapFromMap(map[string]interface{}{
			"id":     "Z0TESTZONE",
			"zoneId": "Z0TESTZONE",
			"name":   "forge-sandbox.fil.one",
		}), nil

	default:
		return nil, fmt.Errorf("mockaws: no answer for provider call %q", args.Token)
	}
}

// NewResource answers a resource registration with its inputs plus whatever
// computed attributes the components read back.
func (Monitor) NewResource(args pulumi.MockResourceArgs) (string, resource.PropertyMap, error) {
	outputs := args.Inputs.Copy()

	id := args.Name + "-id"

	// Attributes AWS computes. Set unconditionally because they are read from
	// several resource types and an unused one is harmless.
	if _, ok := outputs["arn"]; !ok {
		outputs["arn"] = resource.NewStringProperty(fmt.Sprintf("arn:aws:mock:%s:%s:%s", Region, AccountID, args.Name))
	}

	switch args.TypeToken {
	case "aws:rds/instance:Instance":
		outputs["address"] = resource.NewStringProperty(args.Name + ".mock.rds.amazonaws.com")
		outputs["port"] = resource.NewNumberProperty(5432)
		outputs["masterUserSecrets"] = resource.NewArrayProperty([]resource.PropertyValue{
			resource.NewObjectProperty(resource.NewPropertyMapFromMap(map[string]interface{}{
				"secretArn":    fmt.Sprintf("arn:aws:secretsmanager:%s:%s:secret:rds!mock", Region, AccountID),
				"kmsKeyId":     fmt.Sprintf("arn:aws:kms:%s:%s:key/mock-secret-key", Region, AccountID),
				"secretStatus": "active",
			})),
		})

	case "aws:acm/certificate:Certificate":
		// Both entries carry the same record, which is what lets the ingress
		// module write one record for the wildcard and the apex alike.
		option := resource.NewObjectProperty(resource.NewPropertyMapFromMap(map[string]interface{}{
			"domainName":          "forge-sandbox.fil.one",
			"resourceRecordName":  "_acme-challenge.forge-sandbox.fil.one",
			"resourceRecordType":  "CNAME",
			"resourceRecordValue": "mock.acm-validations.aws",
		}))
		outputs["domainValidationOptions"] = resource.NewArrayProperty([]resource.PropertyValue{option, option})

	case "aws:acm/certificateValidation:CertificateValidation":
		// The listener takes its certificate from the validation, not the
		// certificate, so this has to carry one through.
		if _, ok := outputs["certificateArn"]; !ok {
			outputs["certificateArn"] = resource.NewStringProperty("arn:aws:acm:mock")
		}

	case "aws:lb/loadBalancer:LoadBalancer":
		outputs["dnsName"] = resource.NewStringProperty(args.Name + ".mock.elb.amazonaws.com")
		outputs["zoneId"] = resource.NewStringProperty("Z0MOCKALB")

	case "aws:route53/record:Record":
		outputs["fqdn"] = resource.NewStringProperty("mock.forge-sandbox.fil.one")

	case "aws:kms/key:Key":
		outputs["keyId"] = resource.NewStringProperty("mock-key-id")

	case "aws:ecr/repository:Repository":
		outputs["repositoryUrl"] = resource.NewStringProperty(fmt.Sprintf("%s.dkr.ecr.%s.amazonaws.com/forge-central/provision", AccountID, Region))

	case "aws:lambda/invocation:Invocation":
		// A steady-state seed: nothing regenerated, which is the case whose
		// outputs the components read.
		outputs["result"] = resource.NewStringProperty(`{"phase":"seed","dids":{"sprue":"did:key:zMock"},"addresses":{"payer":"0xmock"},"databases":["sprue"],"created":[],"initialised":true}`)

	case "aws:ec2/subnet:Subnet":
		// cidrBlock is an input, so it is already present; the id is what the
		// route tables and the database read.

	case "aws:servicediscovery/privateDnsNamespace:PrivateDnsNamespace":
		// name is an input and is what the internal hostnames are built from.
	}

	return id, outputs, nil
}
