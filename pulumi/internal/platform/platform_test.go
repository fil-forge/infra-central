package platform_test

import (
	"sync"
	"testing"

	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"

	"github.com/fil-forge/infra-central/pulumi/internal/chain"
	"github.com/fil-forge/infra-central/pulumi/internal/mockaws"
	"github.com/fil-forge/infra-central/pulumi/internal/platform"
)

// calibration is the dev stage's chain configuration, which is the one shape the
// components have to accept.
func calibration() chain.Config {
	return chain.Config{
		RPCURL:  "https://api.calibration.node.glif.io/rpc/v1",
		ChainID: 314159,
		Contracts: chain.Contracts{
			FWSS:                    "0x0c6875983B20901a7C3c86871f43FdEE77946424",
			FilecoinPay:             "0x09a0fDc2723fAd1A7b8e3e00eE5DF73841df55a0",
			ServiceProviderRegistry: "0x839e5c9988e4e9977d40708d0094103c0839Ac9D",
			USDFCToken:              "0xb3042734b608a1B16e9e86B374A3f3e389B4cDf0",
		},
	}
}

func devArgs() *platform.Args {
	disabled := false

	return &platform.Args{
		Stage:          "dev",
		ZoneName:       "forge-sandbox.fil.one",
		HostnameSuffix: "dev.forge-sandbox.fil.one",

		ProvisionImageRepositoryURL: mockaws.AccountID + ".dkr.ecr." + mockaws.Region + ".amazonaws.com/forge-central/provision",
		ProvisionImageDigest:        "sha256:bd75f409d0041f7370e019d8a71680bb33a3e1103d4c644405863a017bf33762",

		Chain: calibration(),

		DBInstanceClass:          "db.t4g.micro",
		DBMultiAZ:                &disabled,
		DBBackupRetentionDays:    1,
		ProtectStatefulResources: &disabled,
		OpenBaoMaxParallel:       8,
		SeedTrigger:              "2",
	}
}

// TestBuildsDevStage builds the whole platform composite against a mocked AWS.
//
// It is a smoke test rather than an assertion of shape: what it proves is that
// every resource's inputs are accepted, that the outputs the components read back
// exist, and that no apply panics on the way. Those are exactly the failures a Go
// program can have that the Terraform it replaced could not.
func TestBuildsDevStage(t *testing.T) {
	err := pulumi.RunErr(func(ctx *pulumi.Context) error {
		built, err := platform.New(ctx, "platform", devArgs())
		if err != nil {
			return err
		}

		var waiting sync.WaitGroup
		waiting.Add(4)

		// The seed phase's reported values, decoded from the invocation result.
		built.ServiceDIDs.ApplyT(func(dids map[string]string) error {
			defer waiting.Done()
			if dids["sprue"] != "did:key:zMock" {
				t.Errorf("service dids = %v, want sprue's did among them", dids)
			}

			return nil
		})

		// Empty on a steady-state run, which is the signal nothing was
		// regenerated.
		built.CreatedParameters.ApplyT(func(created []string) error {
			defer waiting.Done()
			if len(created) != 0 {
				t.Errorf("created parameters = %v, want none on a steady-state run", created)
			}

			return nil
		})

		// Built from the private namespace, not read back from the OpenBao
		// service, because the Lambda is created before it.
		built.OpenBaoInternalAddress.ApplyT(func(address string) error {
			defer waiting.Done()
			if address != "http://openbao.forge-central.internal:8200" {
				t.Errorf("openbao internal address = %q", address)
			}

			return nil
		})

		built.OpenBaoPublicURL.ApplyT(func(url string) error {
			defer waiting.Done()
			if url != "https://ssm.dev.forge-sandbox.fil.one" {
				t.Errorf("openbao public url = %q", url)
			}

			return nil
		})

		waiting.Wait()

		return nil
	}, pulumi.WithMocks("forge-central-platform", "dev", mockaws.New()))
	if err != nil {
		t.Fatalf("building the dev platform: %v", err)
	}
}

// TestBuildsProdStage builds the stage whose settings differ in the ways that
// matter: multi-AZ, deletion protection, a final snapshot and a wider connection
// budget.
func TestBuildsProdStage(t *testing.T) {
	args := devArgs()
	protected := true

	args.Stage = "prod"
	args.ZoneName = "forge.fil.one"
	args.HostnameSuffix = "forge.fil.one"
	args.DBInstanceClass = "db.t4g.small"
	args.DBAllocatedStorage = 50
	args.DBMultiAZ = &protected
	args.DBBackupRetentionDays = 30
	args.ProtectStatefulResources = &protected
	args.OpenBaoMaxParallel = 24
	args.ContainerInsights = true

	err := pulumi.RunErr(func(ctx *pulumi.Context) error {
		_, err := platform.New(ctx, "platform", args)

		return err
	}, pulumi.WithMocks("forge-central-platform", "prod", mockaws.New()))
	if err != nil {
		t.Fatalf("building the prod platform: %v", err)
	}
}

// TestRejectsBadConfiguration checks the validation that replaced Terraform's
// variable validation blocks. Each of these used to fail the plan; they have to
// keep failing before anything is created.
func TestRejectsBadConfiguration(t *testing.T) {
	cases := []struct {
		name   string
		breaks func(*platform.Args)
	}{
		{"a tag instead of a digest", func(a *platform.Args) { a.ProvisionImageDigest = "latest" }},
		{"a truncated digest", func(a *platform.Args) { a.ProvisionImageDigest = "sha256:abc" }},
		{"placeholder contract addresses", func(a *platform.Args) {
			a.Chain.Contracts.FWSS = "REPLACE_ME"
		}},
		{"no chain id", func(a *platform.Args) { a.Chain.ChainID = 0 }},
		{"an openbao connection budget that starves the services", func(a *platform.Args) {
			a.OpenBaoMaxParallel = 128
		}},
		{"no hostname suffix", func(a *platform.Args) { a.HostnameSuffix = "" }},
	}

	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			args := devArgs()
			test.breaks(args)

			err := pulumi.RunErr(func(ctx *pulumi.Context) error {
				_, err := platform.New(ctx, "platform", args)

				return err
			}, pulumi.WithMocks("forge-central-platform", "dev", mockaws.New()))
			if err == nil {
				t.Fatal("expected the run to fail, it succeeded")
			}
		})
	}
}
