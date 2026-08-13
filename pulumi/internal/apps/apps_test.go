package apps_test

import (
	"strings"
	"sync"
	"testing"

	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"

	"github.com/fil-forge/infra-central/pulumi/internal/apps"
	"github.com/fil-forge/infra-central/pulumi/internal/chain"
	"github.com/fil-forge/infra-central/pulumi/internal/mockaws"
)

// digests are the dev stage's, whose only property that matters here is that they
// are digests.
func digests() apps.Digests {
	return apps.Digests{
		Sprue:          "sha256:dd4b4f93dfb9cfe4e493cd94c627e6f3f178ad3bc9454d2c9504b206f6cd0f73",
		Hilt:           "sha256:3dbebbfc657632a60192f325b1259365be6bb59083ca1aad4f7d056ea8ba7f13",
		Swarf:          "sha256:6c6c209c7cc88ebd9ce4693db8f675dfeefea6635c438585bb7778f5ad25dfa4",
		Delegator:      "sha256:1df0976e1682d60f71ad32b95025a972fb9f4c8b1df27b835d542424cf782a40",
		SigningService: "sha256:75435d72ebb7cff150548f656e8013962d14262fdb322181249412b79dec2ba5",
		PLC:            "sha256:d68851e5f53ee6511ec628ecfbd4398d8ec55e4625f20c61e1bb74cf5ad17738",
	}
}

// chainOutput is the platform stack's `chain` output as it arrives over a stack
// reference: a nested map with the number decoded as a float64.
func chainOutput() pulumi.Output {
	return pulumi.Any(map[string]interface{}{
		"rpc_url":  "https://api.calibration.node.glif.io/rpc/v1",
		"chain_id": float64(314159),
		"contracts": map[string]interface{}{
			"fwss":                      "0x0c6875983B20901a7C3c86871f43FdEE77946424",
			"filecoin_pay":              "0x09a0fDc2723fAd1A7b8e3e00eE5DF73841df55a0",
			"service_provider_registry": "0x839e5c9988e4e9977d40708d0094103c0839Ac9D",
			"usdfc_token":               "0xb3042734b608a1B16e9e86B374A3f3e389B4cDf0",
		},
	})
}

// devArgs stands in for what the apps program reads out of the platform stack.
func devArgs() *apps.Args {
	return &apps.Args{
		Stage:          "dev",
		HostnameSuffix: pulumi.String("dev.forge-sandbox.fil.one"),

		ClusterArn:      pulumi.String("arn:aws:ecs:us-east-2:654654381893:cluster/fc-dev"),
		VpcID:           pulumi.String("vpc-mock"),
		SubnetIDs:       pulumi.StringArray{pulumi.String("subnet-a"), pulumi.String("subnet-b")},
		SecurityGroupID: pulumi.String("sg-service"),

		ListenerArn:   pulumi.String("arn:aws:elasticloadbalancing:mock:listener"),
		Route53ZoneID: pulumi.String("Z0TESTZONE"),
		AlbDNSName:    pulumi.String("fc-dev.mock.elb.amazonaws.com"),
		AlbZoneID:     pulumi.String("Z0MOCKALB"),

		NamespaceID:   pulumi.String("ns-mock"),
		NamespaceName: pulumi.String("forge-central.internal"),

		BucketNames: pulumi.StringMap{
			"agent-message": pulumi.String("fc-dev-agent-message-654654381893"),
			"delegation":    pulumi.String("fc-dev-delegation-654654381893"),
			"upload-shards": pulumi.String("fc-dev-upload-shards-654654381893"),
		},
		BucketArns: pulumi.StringArray{
			pulumi.String("arn:aws:s3:::fc-dev-agent-message-654654381893"),
			pulumi.String("arn:aws:s3:::fc-dev-delegation-654654381893"),
			pulumi.String("arn:aws:s3:::fc-dev-upload-shards-654654381893"),
		},

		AllowListTableName:    pulumi.String("fc-dev-delegator-allow-list"),
		ProviderInfoTableName: pulumi.String("fc-dev-delegator-provider-info"),
		DynamoDBTableArns: pulumi.StringArray{
			pulumi.String("arn:aws:dynamodb:us-east-2:654654381893:table/fc-dev-delegator-allow-list"),
			pulumi.String("arn:aws:dynamodb:us-east-2:654654381893:table/fc-dev-delegator-provider-info"),
		},

		OpenBaoInternalAddress: pulumi.String("http://openbao.forge-central.internal:8200"),

		IndexerDID:  pulumi.String("did:web:indexer.dev.forge-sandbox.fil.one"),
		EtrackerDID: pulumi.String("did:web:etracker.dev.forge-sandbox.fil.one"),

		ImageDigests: digests(),

		Chain: chain.InputsFrom(chainOutput()),

		AllowProvisionWithoutPaymentPlan: true,
	}
}

// TestBuildsDevApps builds all six services, which is what proves the chain
// configuration survives the trip through the platform stack's output and that
// every service's inputs resolve.
func TestBuildsDevApps(t *testing.T) {
	err := pulumi.RunErr(func(ctx *pulumi.Context) error {
		built, err := apps.New(ctx, "apps", devArgs())
		if err != nil {
			return err
		}

		var waiting sync.WaitGroup

		// plc has no public hostname, matching smelt, so it is absent from the
		// URLs and present among the log groups.
		if _, ok := built.ServiceURLs["plc"]; ok {
			t.Error("plc has a public url; it should have no ALB route at all")
		}
		if _, ok := built.LogGroups["plc"]; !ok {
			t.Error("plc has no log group")
		}
		if len(built.ServiceURLs) != 5 {
			t.Errorf("%d public urls, want 5", len(built.ServiceURLs))
		}

		for _, service := range []string{"sprue", "hilt", "swarf", "delegator", "signing-service"} {
			url, ok := built.ServiceURLs[service]
			if !ok {
				t.Errorf("%s has no public url", service)

				continue
			}

			waiting.Add(1)
			want := "https://" + service + ".dev.forge-sandbox.fil.one"
			url.ToStringOutput().ApplyT(func(got string) error {
				defer waiting.Done()
				if got != want {
					t.Errorf("%s url = %q, want %q", service, got, want)
				}

				return nil
			})
		}

		waiting.Add(1)
		built.PlcInternalURL.ApplyT(func(url string) error {
			defer waiting.Done()
			if url != "http://plc.forge-central.internal:3000" {
				t.Errorf("plc internal url = %q", url)
			}

			return nil
		})

		waiting.Wait()

		return nil
	}, pulumi.WithMocks("forge-central-apps", "dev", mockaws.New()))
	if err != nil {
		t.Fatalf("building the dev apps: %v", err)
	}
}

// TestRejectsUnpinnedImages keeps the guarantee the Terraform variable validation
// gave: a tag here would produce an image reference that pulls at task start and
// fails there instead.
func TestRejectsUnpinnedImages(t *testing.T) {
	args := devArgs()
	args.ImageDigests.Swarf = "main"

	err := pulumi.RunErr(func(ctx *pulumi.Context) error {
		_, err := apps.New(ctx, "apps", args)

		return err
	}, pulumi.WithMocks("forge-central-apps", "dev", mockaws.New()))
	if err == nil {
		t.Fatal("expected a tagged image to fail the run, it succeeded")
	}
}

// TestRejectsMalformedChainOutput checks that a platform stack exporting the wrong
// shape fails the run rather than handing a service an empty endpoint.
func TestRejectsMalformedChainOutput(t *testing.T) {
	args := devArgs()
	args.Chain = chain.InputsFrom(pulumi.Any(map[string]interface{}{
		"rpc_url":   "https://api.calibration.node.glif.io/rpc/v1",
		"chain_id":  float64(314159),
		"contracts": map[string]interface{}{"fwss": "0xabc"},
	}))

	err := pulumi.RunErr(func(ctx *pulumi.Context) error {
		_, err := apps.New(ctx, "apps", args)

		return err
	}, pulumi.WithMocks("forge-central-apps", "dev", mockaws.New()))
	if err == nil {
		t.Fatal("expected a chain output missing filecoin_pay to fail the run, it succeeded")
	}
}

// TestTaskPoliciesGrantExactlyTheirOwnResources is the check the move to
// provider-rendered policy documents would otherwise have lost.
//
// Only sprue and the delegator get any task permissions at all; the other four run
// with a role that grants nothing, which is deliberate. This asserts both halves,
// and that each of the two names its own resources and no others.
func TestTaskPoliciesGrantExactlyTheirOwnResources(t *testing.T) {
	monitor := mockaws.New()

	err := pulumi.RunErr(func(ctx *pulumi.Context) error {
		_, err := apps.New(ctx, "apps", devArgs())

		return err
	}, pulumi.WithMocks("forge-central-apps", "dev", monitor))
	if err != nil {
		t.Fatalf("building the dev apps: %v", err)
	}

	// The four services that should hold no task permissions whatsoever.
	for _, service := range []string{"hilt", "swarf", "signing-service", "plc"} {
		if document, ok := monitor.Policy(service + "-task-service-permissions"); ok {
			t.Errorf("%s has a task policy it should not have: %s", service, document)
		}
	}

	sprue, ok := monitor.Policy("sprue-task-service-permissions")
	if !ok {
		t.Fatal("sprue has no task policy; it needs one for its three buckets")
	}

	// Each bucket named twice: ListBucket acts on the bucket, the object actions
	// on its contents. An unresolved ARN would show up here as a literal "output".
	for _, bucket := range []string{"agent-message", "delegation", "upload-shards"} {
		arn := "arn:aws:s3:::fc-dev-" + bucket + "-654654381893"
		if !strings.Contains(sprue, `"`+arn+`"`) {
			t.Errorf("sprue's policy does not grant the %s bucket itself:\n%s", bucket, sprue)
		}
		if !strings.Contains(sprue, `"`+arn+`/*"`) {
			t.Errorf("sprue's policy does not grant objects in %s:\n%s", bucket, sprue)
		}
	}

	// sprue reaches S3 and nothing else. DynamoDB belongs to the delegator.
	if strings.Contains(sprue, "dynamodb") {
		t.Errorf("sprue's policy reaches dynamodb:\n%s", sprue)
	}

	delegator, ok := monitor.Policy("delegator-task-service-permissions")
	if !ok {
		t.Fatal("the delegator has no task policy; it needs one for its two tables")
	}

	for _, table := range []string{"allow-list", "provider-info"} {
		arn := "arn:aws:dynamodb:us-east-2:654654381893:table/fc-dev-delegator-" + table
		if !strings.Contains(delegator, `"`+arn+`"`) {
			t.Errorf("the delegator's policy does not grant the %s table:\n%s", table, delegator)
		}
	}

	// DescribeTable is load-bearing: the store describes both tables at startup
	// and refuses to run if it cannot.
	if !strings.Contains(delegator, "dynamodb:DescribeTable") {
		t.Errorf("the delegator's policy omits DescribeTable, which it needs at startup:\n%s", delegator)
	}

	if strings.Contains(delegator, "s3:") {
		t.Errorf("the delegator's policy reaches s3:\n%s", delegator)
	}
}
