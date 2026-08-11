package ecsservice

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/pulumi/pulumi/sdk/v3/go/common/resource"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
)

// The wrapper is the part of this module a reader is most likely to get wrong, and
// the part a type checker cannot help with: it is a shell script assembled from
// configuration, where a $NAME has to survive into the container rather than being
// expanded while the program runs.

func TestWrapperLeavesTheEntrypointAloneWithoutAShellCommand(t *testing.T) {
	args := &Args{}

	if got := wrappedCommand(args, ""); got != "" {
		t.Errorf("wrapped command = %q, want empty so the image's own entrypoint stands", got)
	}
}

func TestWrapperPassesAShellCommandThroughWithNoFiles(t *testing.T) {
	args := &Args{}

	if got := wrappedCommand(args, "bao server -config=/tmp/forge/openbao.hcl"); got != "bao server -config=/tmp/forge/openbao.hcl" {
		t.Errorf("wrapped command = %q, want the command unchanged", got)
	}
}

// TestWrapperWritesTextSecrets covers hilt, which takes its identity key only as a
// file path and needs a second file for its upload proof.
func TestWrapperWritesTextSecrets(t *testing.T) {
	args := &Args{
		SecretFiles: map[string]string{
			"HILT_IDENTITY_KEY_PEM": "identity.pem",
			"HILT_UPLOAD_PROOF":     "upload-proof.txt",
		},
	}

	got := wrappedCommand(args, "hilt serve")

	want := "umask 077 && mkdir -p /tmp/forge" +
		" && printf '%s' \"$HILT_IDENTITY_KEY_PEM\" > /tmp/forge/identity.pem && chmod 400 /tmp/forge/identity.pem" +
		" && printf '%s' \"$HILT_UPLOAD_PROOF\" > /tmp/forge/upload-proof.txt && chmod 400 /tmp/forge/upload-proof.txt" +
		" && exec hilt serve"

	if got != want {
		t.Errorf("wrapped command:\n got %q\nwant %q", got, want)
	}
}

// TestWrapperDecodesBinarySecrets covers the delegator, whose two UCAN proofs are
// bare DAG-CBOR and therefore stored base64-encoded: their raw bytes contain NULs,
// which an environment variable cannot carry.
func TestWrapperDecodesBinarySecrets(t *testing.T) {
	args := &Args{
		SecretFilesBase64: map[string]string{
			"DELEGATOR_INDEXING_PROOF": "indexing-service-proof.txt",
			"DELEGATOR_EGRESS_PROOF":   "egress-tracking-proof.txt",
		},
	}

	got := wrappedCommand(args, "registrar serve")

	if !strings.Contains(got, "printf '%s' \"$DELEGATOR_EGRESS_PROOF\" | base64 -d > /tmp/forge/egress-tracking-proof.txt") {
		t.Errorf("wrapped command does not decode the egress proof: %q", got)
	}
	if !strings.HasSuffix(got, " && exec registrar serve") {
		t.Errorf("wrapped command does not exec the process last: %q", got)
	}
}

// TestWrapperIsStable is the one that matters for churn. Go map iteration order is
// random, so an unsorted wrapper would rewrite the task definition on every run and
// restart every task. Terraform's maps were sorted for it; here it is deliberate.
func TestWrapperIsStable(t *testing.T) {
	args := &Args{
		SecretFiles: map[string]string{
			"D_KEY": "d.pem",
			"A_KEY": "a.pem",
			"C_KEY": "c.pem",
			"B_KEY": "b.pem",
		},
	}

	first := wrappedCommand(args, "serve")
	for attempt := 0; attempt < 50; attempt++ {
		if got := wrappedCommand(args, "serve"); got != first {
			t.Fatalf("wrapper is not stable across runs:\n %q\n %q", first, got)
		}
	}

	// Sorted by environment variable name, so the order is a stated fact rather
	// than whatever the map yielded.
	if want := []string{"a.pem", "b.pem", "c.pem", "d.pem"}; !inOrder(first, want) {
		t.Errorf("wrapper writes files out of order: %q", first)
	}
}

func inOrder(haystack string, needles []string) bool {
	at := 0
	for _, needle := range needles {
		index := strings.Index(haystack[at:], needle)
		if index < 0 {
			return false
		}
		at += index + len(needle)
	}

	return true
}

// TestValidationRejectsAFileWithoutItsSecret keeps the guarantee the Terraform
// variable validation gave: a missing entry writes an empty file and the service
// fails at startup with an unhelpful parse error.
func TestValidationRejectsAFileWithoutItsSecret(t *testing.T) {
	args := &Args{
		Stage:              "dev",
		Service:            "hilt",
		Region:             "us-east-2",
		AccountID:          "654654381893",
		ContainerPort:      8080,
		HealthCheckCommand: "curl -sf http://127.0.0.1:8080/health",
		ShellCommand:       pulumi.String("hilt serve"),
		SecretFiles:        map[string]string{"HILT_IDENTITY_KEY_PEM": "identity.pem"},
	}

	if err := args.defaults(); err == nil {
		t.Fatal("expected a secret file with no matching secret to be rejected")
	}
}

// TestValidationRequiresAShellCommandForFiles covers the other half of the same
// pairing: writing a secret to a file replaces the image entrypoint, so something
// has to say what to exec afterwards.
func TestValidationRequiresAShellCommandForFiles(t *testing.T) {
	args := &Args{
		Stage:              "dev",
		Service:            "hilt",
		Region:             "us-east-2",
		AccountID:          "654654381893",
		ContainerPort:      8080,
		HealthCheckCommand: "curl -sf http://127.0.0.1:8080/health",
		Secrets:            pulumi.StringMap{"HILT_IDENTITY_KEY_PEM": pulumi.String("arn:aws:ssm:mock")},
		SecretFiles:        map[string]string{"HILT_IDENTITY_KEY_PEM": "identity.pem"},
	}

	if err := args.defaults(); err == nil {
		t.Fatal("expected secret files with no shell command to be rejected")
	}
}

// TestContainerDefinitionIsSortedAndComplete renders a definition and checks the
// parts ECS is strict about, plus the ordering that keeps a steady-state run from
// producing a new task definition revision.
func TestContainerDefinitionIsSortedAndComplete(t *testing.T) {
	args := &Args{
		Stage:                  "dev",
		Service:                "sprue",
		Region:                 "us-east-2",
		AccountID:              "654654381893",
		ContainerPort:          8080,
		Image:                  pulumi.String("ghcr.io/fil-forge/sprue@sha256:abc"),
		HealthCheckCommand:     "curl -sf http://127.0.0.1:8080/health",
		HealthCheckStartPeriod: 90,
		Environment: pulumi.StringMap{
			"SPRUE_SERVER_PORT": pulumi.String("8080"),
			"SPRUE_LOG_LEVEL":   pulumi.String("info"),
			"SPRUE_MAILER_TYPE": pulumi.String("nop"),
		},
		Secrets: pulumi.StringMap{
			"SPRUE_IDENTITY_KEY_PEM":     pulumi.String("arn:aws:ssm:mock:identity"),
			"SPRUE_STORAGE_POSTGRES_DSN": pulumi.String("arn:aws:ssm:mock:dsn"),
		},
		SecretFiles:  map[string]string{"SPRUE_IDENTITY_KEY_PEM": "identity.pem"},
		ShellCommand: pulumi.String("sprue serve"),
	}

	rendered := renderSynchronously(t, args)

	var definitions []struct {
		Name        string     `json:"name"`
		Image       string     `json:"image"`
		Essential   bool       `json:"essential"`
		EntryPoint  []string   `json:"entryPoint"`
		Command     []string   `json:"command"`
		Environment []keyValue `json:"environment"`
		Secrets     []struct {
			Name      string `json:"name"`
			ValueFrom string `json:"valueFrom"`
		} `json:"secrets"`
		HealthCheck struct {
			Command []string `json:"command"`
		} `json:"healthCheck"`
		LogConfiguration struct {
			LogDriver string            `json:"logDriver"`
			Options   map[string]string `json:"options"`
		} `json:"logConfiguration"`
	}

	if err := json.Unmarshal([]byte(rendered), &definitions); err != nil {
		t.Fatalf("rendered definition is not valid json: %v\n%s", err, rendered)
	}
	if len(definitions) != 1 {
		t.Fatalf("%d container definitions, want 1", len(definitions))
	}

	definition := definitions[0]

	if definition.Name != "sprue" || !definition.Essential {
		t.Errorf("definition names %q, essential %v", definition.Name, definition.Essential)
	}

	// Sorted, so an unchanged configuration renders byte-identically.
	wantEnv := []string{"SPRUE_LOG_LEVEL", "SPRUE_MAILER_TYPE", "SPRUE_SERVER_PORT"}
	for index, name := range wantEnv {
		if definition.Environment[index].Name != name {
			t.Errorf("environment[%d] = %q, want %q", index, definition.Environment[index].Name, name)
		}
	}

	if definition.Secrets[0].Name != "SPRUE_IDENTITY_KEY_PEM" {
		t.Errorf("secrets are not sorted: %v", definition.Secrets)
	}

	// The wrapper replaced the entrypoint, so the shell has to be it.
	if len(definition.EntryPoint) != 2 || definition.EntryPoint[0] != "/bin/sh" {
		t.Errorf("entry point = %v, want the shell", definition.EntryPoint)
	}
	if len(definition.Command) != 1 || !strings.HasSuffix(definition.Command[0], "exec sprue serve") {
		t.Errorf("command = %v, want the wrapper ending in exec", definition.Command)
	}

	// ECS needs CMD-SHELL, and the trailing exit keeps a non-zero status from the
	// check itself from being read as healthy.
	if definition.HealthCheck.Command[0] != "CMD-SHELL" {
		t.Errorf("health check = %v", definition.HealthCheck.Command)
	}
	if !strings.HasSuffix(definition.HealthCheck.Command[1], " || exit 1") {
		t.Errorf("health check does not fail closed: %v", definition.HealthCheck.Command)
	}

	if definition.LogConfiguration.Options["awslogs-region"] != "us-east-2" {
		t.Errorf("log configuration = %v", definition.LogConfiguration)
	}
	if definition.LogConfiguration.Options["awslogs-group"] != "/forge-central/dev/sprue" {
		t.Errorf("log group = %q", definition.LogConfiguration.Options["awslogs-group"])
	}
}

// renderSynchronously resolves the container definition output, so a test can
// assert on the JSON rather than on the plumbing that produces it.
func renderSynchronously(t *testing.T, args *Args) string {
	t.Helper()

	if err := args.defaults(); err != nil {
		t.Fatalf("defaults: %v", err)
	}

	var rendered string
	done := make(chan struct{})

	err := pulumi.RunErr(func(ctx *pulumi.Context) error {
		containerDefinitions(args, pulumi.String("/forge-central/dev/sprue").ToStringOutput()).
			ApplyT(func(definition string) error {
				rendered = definition
				close(done)

				return nil
			})

		<-done

		return nil
	}, pulumi.WithMocks("forge-central-apps", "dev", monitor{}))
	if err != nil {
		t.Fatalf("rendering the container definition: %v", err)
	}

	return rendered
}

// monitor is a do-nothing resource monitor: this test registers no resources, it
// only needs a context in which outputs resolve.
type monitor struct{}

func (monitor) Call(pulumi.MockCallArgs) (resource.PropertyMap, error) { return nil, nil }

func (monitor) NewResource(args pulumi.MockResourceArgs) (string, resource.PropertyMap, error) {
	return args.Name, args.Inputs, nil
}
