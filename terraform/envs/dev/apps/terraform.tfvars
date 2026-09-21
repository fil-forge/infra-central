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
  sprue = "sha256:5dda5c781a8e017093114bf24950158b1d6f75726a628565bc3b981dc1392c35"

  hilt = "sha256:482e9a50216ebe0e7936574c54429666d4eb3f244ebaf955c0465e2b5bccff47"

  swarf = "sha256:6554c9c71caff72fc099c0578edcf9084b8bee7a2747f6161160b9faba9062f5"

  delegator = "sha256:30b1757986ce213a8eecacbd7a463142a242b0f3932180796aad62c2f2ccc2fe"

  signing_service = "sha256:b7ef5f0ea7e035c183d69ae90c98f30a4e04b944dfbf7ccbf27608e1b904e461"

  plc = "sha256:ebb12470f6fc50906c0ed867d009a056e131db1a994b45d7c3f1c8d2eb26dee9"
}
