// Package chain carries a stage's chain and contract configuration.
//
// One home per stage: the platform stack owns it and the apps stack reads it
// from that stack's outputs rather than keeping a second copy, mirroring
// smelt's shared smart-contracts.env.
package chain

import (
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"

	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
)

// Config is the whole of a stage's chain configuration. The field tags are what
// let a stack read it out of `forge-central:chain` with config.RequireObject and
// hand it back to the apps stack through a stack output unchanged.
type Config struct {
	RPCURL    string    `json:"rpc_url"`
	ChainID   int       `json:"chain_id"`
	Contracts Contracts `json:"contracts"`
}

// Contracts holds the proxy addresses the services and the fund phase call.
// Public on-chain addresses: a contract redeployment should arrive as a
// reviewable diff.
type Contracts struct {
	FWSS                    string `json:"fwss"`
	FilecoinPay             string `json:"filecoin_pay"`
	ServiceProviderRegistry string `json:"service_provider_registry"`
	USDFCToken              string `json:"usdfc_token"`
}

// address matches an EIP-55 or lowercase hex contract address. Case is not
// checked: a mixed-case address carries a checksum this project has no reason
// to verify, and the services accept either form.
var address = regexp.MustCompile(`^0x[0-9a-fA-F]{40}$`)

// Validate reports whether the configuration is usable, replacing the type
// constraint the Terraform variable's object type gave for free.
//
// Prod's contract addresses are committed as REPLACE_ME on purpose: smelt only
// ever configured Calibration, so the mainnet deployment addresses have to come
// from the contracts team before the first prod up. Leaving them obviously
// wrong is deliberate, and this is where that becomes a preview-time failure
// rather than a transaction-time one.
func (c Config) Validate() error {
	var problems []string

	if c.RPCURL == "" {
		problems = append(problems, "rpc_url is empty")
	} else if !strings.HasPrefix(c.RPCURL, "https://") && !strings.HasPrefix(c.RPCURL, "http://") {
		problems = append(problems, fmt.Sprintf("rpc_url %q is not an http or https URL", c.RPCURL))
	}

	if c.ChainID == 0 {
		problems = append(problems, "chain_id is unset")
	}

	// A slice rather than a map, so the message reads the same on every run.
	contracts := []struct {
		name  string
		value string
	}{
		{"fwss", c.Contracts.FWSS},
		{"filecoin_pay", c.Contracts.FilecoinPay},
		{"service_provider_registry", c.Contracts.ServiceProviderRegistry},
		{"usdfc_token", c.Contracts.USDFCToken},
	}

	for _, contract := range contracts {
		if !address.MatchString(contract.value) {
			problems = append(problems, fmt.Sprintf("contracts.%s is %q, not an 0x-prefixed 20-byte address", contract.name, contract.value))
		}
	}

	if len(problems) == 0 {
		return nil
	}

	return errors.New("chain configuration: " + strings.Join(problems, "; "))
}

// Inputs is a chain configuration whose values are not known while the program
// builds its graph, because the stack that owns them has not been read yet.
//
// The apps stack is in exactly that position: the platform stack owns the
// configuration and exports it, so apps sees five outputs rather than five
// strings. Only these five appear here — usdfc_token is used by the fund phase
// alone, which lives on the platform side.
//
// Every value is pre-rendered as a string, because all five are destined for
// environment variables.
type Inputs struct {
	RPCURL                  pulumi.StringInput
	ChainID                 pulumi.StringInput
	FWSS                    pulumi.StringInput
	FilecoinPay             pulumi.StringInput
	ServiceProviderRegistry pulumi.StringInput
}

// ToInputs converts a configuration a stack already knows, for the stack that
// owns it.
func (c Config) ToInputs() Inputs {
	return Inputs{
		RPCURL:                  pulumi.String(c.RPCURL),
		ChainID:                 pulumi.String(strconv.Itoa(c.ChainID)),
		FWSS:                    pulumi.String(c.Contracts.FWSS),
		FilecoinPay:             pulumi.String(c.Contracts.FilecoinPay),
		ServiceProviderRegistry: pulumi.String(c.Contracts.ServiceProviderRegistry),
	}
}

// InputsFrom reads the configuration out of another stack's `chain` output.
//
// The owning stack validated the whole object before it created anything, so this
// checks only that the shape survived the round trip. A missing or mistyped field
// fails the run from inside the apply rather than producing an empty environment
// variable a service would fail on much later.
func InputsFrom(object pulumi.Output) Inputs {
	text := func(path ...string) pulumi.StringInput {
		return object.ApplyT(func(raw interface{}) (string, error) {
			return dig(raw, path)
		}).(pulumi.StringOutput)
	}

	return Inputs{
		RPCURL:                  text("rpc_url"),
		ChainID:                 text("chain_id"),
		FWSS:                    text("contracts", "fwss"),
		FilecoinPay:             text("contracts", "filecoin_pay"),
		ServiceProviderRegistry: text("contracts", "service_provider_registry"),
	}
}

// dig walks the decoded object and renders the value at path as a string. A
// stack output arrives as nested map[string]interface{}, with numbers decoded as
// float64, which is why chain_id needs a case of its own.
func dig(raw interface{}, path []string) (string, error) {
	for index, key := range path {
		object, ok := raw.(map[string]interface{})
		if !ok {
			return "", fmt.Errorf("chain output: %s is not an object", strings.Join(path[:index], "."))
		}

		raw, ok = object[key]
		if !ok {
			return "", fmt.Errorf("chain output: %s is missing", strings.Join(path[:index+1], "."))
		}
	}

	switch value := raw.(type) {
	case string:
		if value == "" {
			return "", fmt.Errorf("chain output: %s is empty", strings.Join(path, "."))
		}

		return value, nil
	case float64:
		return strconv.FormatFloat(value, 'f', -1, 64), nil
	case int:
		return strconv.Itoa(value), nil
	default:
		return "", fmt.Errorf("chain output: %s is a %T, want a string or a number", strings.Join(path, "."), raw)
	}
}

// ToMap renders the configuration for export, so the stack that owns it publishes
// one object rather than five loose values.
//
// The keys are spelled the way InputsFrom reads them, and the way the Terraform
// variable spelled them, so a stage's committed configuration needs no edit to be
// understood on either side.
func (c Config) ToMap() pulumi.Map {
	return pulumi.Map{
		"rpc_url":  pulumi.String(c.RPCURL),
		"chain_id": pulumi.Int(c.ChainID),
		"contracts": pulumi.Map{
			"fwss":                      pulumi.String(c.Contracts.FWSS),
			"filecoin_pay":              pulumi.String(c.Contracts.FilecoinPay),
			"service_provider_registry": pulumi.String(c.Contracts.ServiceProviderRegistry),
			"usdfc_token":               pulumi.String(c.Contracts.USDFCToken),
		},
	}
}
