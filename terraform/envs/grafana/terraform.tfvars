# Replace before the first apply. A service account id of 0 matches nothing, so
# the folder permission would grant Admin to nobody and lock this root out of the
# folder it just created. The id is on Administration -> Users and access ->
# Service accounts, in the URL of the forge-dashboards-terraform account.
dashboards_service_account_id = "0"
