package onboard

import (
	"testing"

	adminprovider "github.com/fil-forge/hilt/pkg/commands/admin/provider"
	"github.com/fil-forge/ucantone/did"
)

func TestFindProviderPicksTheEntryForTheDID(t *testing.T) {
	ingot := did.MustParse("did:web:s3.us-east-9.example")
	other := did.MustParse("did:web:s3.eu-central-3.example")
	policy := did.MustParse("did:key:z6MkjFRxLLGdBqQSLkZbVnuwUFiomK8eGBkPtim9ETvP7vec")
	list := []adminprovider.Provider{
		{Provider: other, Region: "eu-central-3"},
		{Provider: ingot, Region: "us-east-9", Policy: &policy},
	}

	got := findProvider(list, ingot)
	if got == nil || got.Region != "us-east-9" || got.Policy != policy.String() {
		t.Fatalf("findProvider() = %+v, want us-east-9 with policy %s", got, policy)
	}

	// A provider hilt holds without a policy reports an empty one.
	got = findProvider(list, other)
	if got == nil || got.Region != "eu-central-3" || got.Policy != "" {
		t.Fatalf("findProvider() = %+v, want eu-central-3 with no policy", got)
	}

	if got := findProvider(list, did.MustParse("did:web:s3.ap-south-7.example")); got != nil {
		t.Fatalf("findProvider() = %+v for an unregistered DID, want nil", got)
	}
}
