# Uid of the hand-made Forge folder the three below nest under. Unlike theirs it
# is whatever Grafana generated, because it is made in the UI rather than through
# the API. Short and opaque where the children's are meaningful; that asymmetry
# is the price of the UI not letting you choose one.
parent_folder_uid = "fhmttd"

# These are the numeric ids, not the uids. Administration -> Users and access ->
# Service accounts -> the account: the page body states "Numeric ID: <n>". The
# uid in the address bar (ffz5ccdye1a80a and the like) is a different
# identifier and grafana_folder_permission does not accept it.
#
# A service account id of 0 matches nothing, so a placeholder left here grants
# the permission to nobody -- and for the account below, locks this root out of
# the folders it just created.
terraform_service_account_id = "83"

# forge-sync. Named by the dashboards folder permission, which grants it View so
# the sync workflow can read a dashboard back out of Grafana to raise the pull
# request that returns a UI edit to git.
sync_service_account_id = "84"

# forge-previews. Admin on the previews folder and nothing else, because the
# preview workflow runs on pull_request and its credential is reachable by any
# action a pull request brings with it. Scoped this way the worst case is a
# trashed preview.
previews_service_account_id = "85"

# The grafanacloud-prom data source's uid happens to equal its name, read off an
# alert rule exported from the stack. Alert rules address a data source by uid
# where a dashboard can use its name. Not a secret.
prometheus_datasource_uid = "grafanacloud-prom"

# Staging, not the variable's production-only default: production does not exist
# yet (FIL-1147, FIL-808) and staging is what the hand-built rules these replace
# were watching. Add "prod" alongside, or replace staging with it, once the prod
# stage is stood up.
alert_stages = ["staging"]
