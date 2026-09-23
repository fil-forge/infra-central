# These are the numeric ids, not the uids. Administration -> Users and access ->
# Service accounts -> the account: the page body states "Numeric ID: <n>". The
# uid in the address bar (ffz5ccdye1a80a and the like) is a different
# identifier and grafana_folder_permission does not accept it.
#
# A service account id of 0 matches nothing, so a placeholder left here grants
# the permission to nobody -- and for the account below, locks this root out of
# the folders it just created.
terraform_service_account_id = "83"

# Replace before the first apply: the dashboards folder permission names this
# account, so a placeholder grants View to nobody and the sync workflow cannot
# read a dashboard back.
sync_service_account_id = "0"

# Replace before the previews folder is of any use. The forge-previews service
# account holds Admin on that folder and nothing else, because the preview
# workflow runs on pull_request and its credential is reachable by any action a
# pull request brings with it.
previews_service_account_id = "0"
