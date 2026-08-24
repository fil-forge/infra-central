package main

// Parameter naming for regional appliances.
//
// Each region gets its own parameter prefix, /forge-central/<stage>/appliance/
// <region>/, so retiring one is a prefix to delete rather than a list of names
// to remember. The stage's services keep their own prefixes untouched.

// unsealTokenAccessorKey names the parameter holding the accessor of the
// region's unseal token.
//
// The accessor, not the token. An accessor cannot authenticate: it can only be
// used to look a token up or revoke it, which is exactly what this stage needs
// it for and is why it is stored as a plain String. The token itself is never
// stored anywhere in AWS; it is delivered once to the node.
const unsealTokenAccessorKey = "unseal-token.accessor"

// applianceService renders the ssmstore service prefix for a region.
func applianceService(region string) string {
	return "appliance/" + region
}
