# Who invoked prod's provision Lambda, to S3 and to Grafana. See
# modules/provision-invocations and the non-prod copy of this file.

module "provision_invocations" {
  source = "../../../../modules/provision-invocations"

  stages            = module.constants.prod_stages
  log_firehose_arns = module.telemetry.log_firehose_arns
}

output "provision_invocations_trail" {
  value = module.provision_invocations.trail_name
}

output "provision_invocations_bucket" {
  value = module.provision_invocations.trail_bucket
}
