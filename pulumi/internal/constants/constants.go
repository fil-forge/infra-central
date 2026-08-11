// Package constants holds the values more than one Pulumi project has to agree
// on.
//
// This replaces the shared/constants Terraform module, which existed because
// root modules cannot share a variable and a literal copied into several of
// them drifts. A Go package is the natural form here: every project imports it
// and the compiler enforces the spelling.
package constants

// Organization is the Pulumi organization every stack in this project lives in.
// It is the first segment of a fully qualified stack name, which is how the apps
// stack addresses the platform stack it reads.
const Organization = "Filecoin_Foundation"

// PlatformProject and AppsProject are the Pulumi project names. The apps stack
// builds a stack reference out of PlatformProject and its own stack name, so the
// two projects have to agree on the spelling.
const (
	PlatformProject = "forge-central-platform"
	AppsProject     = "forge-central-apps"
)

// NonprodAccountID is filone-sandbox, holding every non-prod stage and the
// bootstrap stacks that feed them.
const NonprodAccountID = "654654381893"

// ProdAccountID is filone-production, holding the prod stage and its bootstrap
// stacks.
const ProdAccountID = "811430801166"

// ProvisionRepositoryName is the ECR repository holding the provision Lambda
// image. A stage derives its image URL from this name plus its own account and
// region, so the URL cannot disagree with the repository the bootstrap stack
// created.
const ProvisionRepositoryName = "forge-central/provision"

// AccountID returns the account a stage of the given kind belongs to. Stages
// name themselves prod or non-prod rather than repeating an account number,
// which is what keeps the provider's account guard and the derived ECR URL in
// step.
func AccountID(prod bool) string {
	if prod {
		return ProdAccountID
	}
	return NonprodAccountID
}
