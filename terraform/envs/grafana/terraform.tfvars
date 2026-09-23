# Replace before the first apply. A service account id of 0 matches nothing, so
# the folder permission would grant Admin to nobody and lock this root out of the
# folder it just created. The id is on Administration -> Users and access ->
# Service accounts, in the URL of the forge-terraform account.
terraform_service_account_id = "0"

# Replace before the first apply, for the same reason as the id above: the
# dashboards folder permission names this account, so a placeholder grants View
# to nobody. The sync workflow cannot read a dashboard back until it is right.
sync_service_account_id = "0"

# Replace before the previews folder is of any use. The forge-previews service
# account holds Admin on that folder and nothing else, because the preview
# workflow runs on pull_request and its credential is reachable by any action a
# pull request brings with it.
previews_service_account_id = "0"
