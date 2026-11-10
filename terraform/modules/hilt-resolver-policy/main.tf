# Exact inbound UCAN issuer/proof identities. Hilt resolves its own identity
# locally, and did:key requires no HTTP; neither belongs in this egress list.
locals {
  allowed_web_dids = sort(distinct([
    for name in var.appliance_key_names :
    "did:web:s3.${trimprefix(name, "appliance-unseal-")}.${var.ingot_hostname_suffix}"
  ]))
}
