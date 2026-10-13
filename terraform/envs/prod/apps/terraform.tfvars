# Pinned per service, by digest. A digest names one artifact and cannot move
# underneath a running service, so a redeploy cannot silently change what runs.
#
# Seeded from the digests staging ran when prod was created. Later versions
# arrive by merging the "Promote staging's images to prod" pull request, which
# scripts/promote.sh keeps open.
#
# The blank lines between the pins are what keeps two services' bumps from
# conflicting. Each bump rewrites one line, and git conflicts on changes to
# adjacent lines.
image_digests = {
  sprue = "sha256:79eb33d967f163fb7370ce4cacb757428f551466625e191ed774efa949327cb1"

  hilt = "sha256:80076f3f7bc0d8a005b44283a2b5f369d8a2eec686fe64c6a9c819661ea83e10"

  swarf = "sha256:c3643127f22e47c9ea8f479287ffc1ef01e9d29d2fe9ebe5fc76488501803a74"

  delegator = "sha256:30b1757986ce213a8eecacbd7a463142a242b0f3932180796aad62c2f2ccc2fe"

  signing_service = "sha256:b7ef5f0ea7e035c183d69ae90c98f30a4e04b944dfbf7ccbf27608e1b904e461"

  plc = "sha256:ebb12470f6fc50906c0ed867d009a056e131db1a994b45d7c3f1c8d2eb26dee9"
}
