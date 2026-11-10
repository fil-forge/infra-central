# Pinned per service, by digest. A digest names one artifact and cannot move
# underneath a running service, so what dev runs is what was merged rather than
# whatever a rolling tag pointed at when a task last restarted.
#
# These are the manifest indexes each repository's `main` tag pointed at when
# the stage was first brought up. Each carries linux/arm64, which the tasks run
# on. Bump one by reading the digest its tag now names:
#
#   crane digest ghcr.io/fil-forge/sprue:main
#
# The blank lines between the pins are what keeps two services' bumps from
# conflicting. Each bump rewrites one line, and git conflicts on changes to
# adjacent lines, so six consecutive pins made every pair of open bump pull
# requests a conflict waiting for the second one to merge.
image_digests = {
  sprue = "sha256:8a9a661c62ddeb5c5382e974c5fa8357f9f4db694b2dcc489103e8882d2ba5b6"

  hilt = "sha256:b2a5c96966aa2b37bad6b3d3e7216dce6b93208f5c0d3ecf9c6523632d8ccc9d"

  swarf = "sha256:e14607ef2ae00409c5342145dc01b01901d8dcb4e4f124a76ea5a19732fcc695"

  delegator = "sha256:06ede396eb1ed1ab56ecafc4ae754443ddd6f259b161e22e20264dfca5c5d839"

  signing_service = "sha256:4493534d96a4f7f202e58f8811b7258da7feda4d79e710473c903f99ace76a98"

  plc = "sha256:ebb12470f6fc50906c0ed867d009a056e131db1a994b45d7c3f1c8d2eb26dee9"
}
