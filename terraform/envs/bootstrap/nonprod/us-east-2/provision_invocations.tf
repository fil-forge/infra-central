# Who invoked dev's and staging's provision Lambdas, to S3 and to Grafana. In a
# file of its own so it sits apart from the telemetry module whose Firehoses it
# ships to. See modules/provision-invocations.

module "provision_invocations" {
  source = "../../../../modules/provision-invocations"

  stages            = module.constants.nonprod_stages
  log_firehose_arns = module.telemetry.log_firehose_arns
}

output "provision_invocations_trail" {
  value = module.provision_invocations.trail_name
}

output "provision_invocations_bucket" {
  value = module.provision_invocations.trail_bucket
}
