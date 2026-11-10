run "stage_isolation" {
  command = plan
  variables {
    ingot_hostname_suffix = "latest.dev.filonecontent.com"
    appliance_key_names   = ["appliance-unseal-us-east-9", "appliance-unseal-eu-central-3", "appliance-unseal-us-east-9"]
  }
  assert {
    condition = output.allowed_web_dids == tolist([
      "did:web:s3.eu-central-3.latest.dev.filonecontent.com",
      "did:web:s3.us-east-9.latest.dev.filonecontent.com",
    ])
    error_message = "Only exact current-stage appliance identities may be admitted, with deterministic deduplication."
  }
}

run "no_appliances_denies_all_external_web" {
  command = plan
  variables {
    ingot_hostname_suffix = "filonecontent.com"
    appliance_key_names   = []
  }
  assert {
    condition     = length(output.allowed_web_dids) == 0
    error_message = "An empty inventory must not turn into a wildcard allowlist."
  }
}

run "region_cannot_inject_another_did" {
  command = plan
  variables {
    ingot_hostname_suffix = "staging.filonecontent.com"
    appliance_key_names   = ["appliance-unseal-eu-central-3,did:web:elsewhere.example"]
  }
  expect_failures = [var.appliance_key_names]
}

run "suffix_cannot_admit_wildcards" {
  command = plan
  variables {
    ingot_hostname_suffix = "*.filonecontent.com"
    appliance_key_names   = ["appliance-unseal-us-east-9"]
  }
  expect_failures = [var.ingot_hostname_suffix]
}

run "unrelated_transit_key_is_not_an_appliance" {
  command = plan
  variables {
    ingot_hostname_suffix = "staging.filonecontent.com"
    appliance_key_names   = ["another-purpose-us-east-9"]
  }
  expect_failures = [var.appliance_key_names]
}
