# Each case plans only the appliance backups module, which reads appliances,
# against a mock AWS: no credentials, and none of the mock values the rest of
# the module would reject. A target leaves out the validations of variables it
# does not read, so it has to be one that reads appliances.
mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{}" }
  }
}

variables {
  stage                          = "any-stage"
  hostname_suffix                = "any.example"
  ingot_hostname_suffix          = "ingot.any.example"
  provision_image_repository_url = "000000000000.dkr.ecr.us-east-2.amazonaws.com/any"
  provision_image_digest         = "sha256:0000000000000000000000000000000000000000000000000000000000000000"
  db_engine_version              = "16"
  appliance_backups              = { retention_days = 1 }
  chain = {
    rpc_url  = "https://rpc.any.example"
    chain_id = 1
    contracts = {
      fwss                      = "0x0000000000000000000000000000000000000001"
      filecoin_pay              = "0x0000000000000000000000000000000000000002"
      service_provider_registry = "0x0000000000000000000000000000000000000003"
      usdfc_token               = "0x0000000000000000000000000000000000000004"
    }
  }
}

run "accepts_bare_ipv4_addresses_for_live_regions" {
  command = plan

  plan_options {
    target = [module.appliance_backups]
  }

  variables {
    appliances                = { any-region = "203.0.113.7", other-region = "198.51.100.9" }
    retired_appliance_regions = ["retired-region"]
  }
}

run "rejects_an_appliance_address_with_a_prefix_length" {
  command = plan

  plan_options {
    target = [module.appliance_backups]
  }

  variables {
    # A CIDR, not a bare address.
    appliances = { any-region = "203.0.113.7/32" }
  }

  expect_failures = [var.appliances]
}

run "rejects_an_appliance_address_that_is_not_IPv4" {
  command = plan

  plan_options {
    target = [module.appliance_backups]
  }

  variables {
    # IPv6, which the signer's IPv4 load balancer never sees as a source.
    appliances = { any-region = "2001:db8::1" }
  }

  expect_failures = [var.appliances]
}

run "rejects_an_appliance_whose_region_is_also_retired" {
  command = plan

  plan_options {
    target = [module.appliance_backups]
  }

  variables {
    appliances = { any-region = "203.0.113.7" }
    # The same label in both lists.
    retired_appliance_regions = ["any-region"]
  }

  expect_failures = [var.appliances]
}
