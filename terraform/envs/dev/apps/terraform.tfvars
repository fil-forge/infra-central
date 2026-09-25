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
  sprue = "sha256:1b0a8bc8b2b80ff1781cc0294d9de902d41923e3b2abff20132079e9dbddff8c"

  hilt = "sha256:94ddb1ec527a9d82abf4f54804614dbf192c6b06588336c696d101d3be91acff"

  swarf = "sha256:b090ceb720eed695f48afba8c22b1f2946781bb4584316b8176b247598f0e2bf"

  delegator = "sha256:30b1757986ce213a8eecacbd7a463142a242b0f3932180796aad62c2f2ccc2fe"

  signing_service = "sha256:b7ef5f0ea7e035c183d69ae90c98f30a4e04b944dfbf7ccbf27608e1b904e461"

  plc = "sha256:ebb12470f6fc50906c0ed867d009a056e131db1a994b45d7c3f1c8d2eb26dee9"
}
